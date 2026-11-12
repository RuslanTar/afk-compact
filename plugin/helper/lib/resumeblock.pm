package resumeblock;
# lib/resumeblock.pm: the post-compaction resume block:
# resume-context.txt with [midturn]/[nonok], exactly one of [prod-forbid]/[prod-allow], and
# [driver] when the re-measure names this session's Active driver (lib/gsd.pm),
# [auto-mode] when the newest main Stop ran in auto permission mode, [resumed] with the
# fixed first line (0.1.3: this path reads no Step 1, see $RESUMED_FALLBACK) unless a
# script reads the reply (0.1.4, script_reader),
# @session_id@, @saved_copy@, @measured_at@, @remeasure@ (<= 3,000 B), @store@. Total soft
# 6,500 chars (soft, not a hard limit): a block over it logs resume_block_over_soft {nonce, chars}. Hard runtime cap
# 9,500 chars, under the 10,000-char SessionStart cutoff: over it the measured block is cut first,
# at a line boundary. No transcript path.
use strict;
use warnings;
use utf8;

our $MAX_CHARS = 9500;
our $SOFT_CHARS = 6500;
# 0.1.3 resume-text A: the [resumed] line's fixed text, as resume.ts RESUMED_FALLBACK. The classic
# SessionStart(compact) payload has no summary, and its copy is saved by PostCompact around the
# same time (the saved-copy line says pending), so this path has no Step 1 to show.
# 0.1.4 probe (Claude Code 2.1.317, a scratch plugin logging both hooks with a 1 s
# PostCompact): in all 6 compactions (3 `claude -p --resume <id> /compact`, 3 `/compact` in a
# terminal session) SessionStart(compact) started and ended before PostCompact started, and the
# mod's session.compact returned after PostCompact. So no copy or summary of this compaction exists
# when this path builds its block: the fixed form stays.
our $RESUMED_FALLBACK = 'Resumed after compaction';

# 0.1.4: CLAUDE_CODE_ENTRYPOINT values whose reply a script reads (`claude -p`: sdk-cli; the
# Agent SDK: sdk-ts, sdk-py). A probe on 2.1.317: every hook of a `-p` run saw sdk-cli, every
# hook of a terminal session cli.
our %SCRIPT_ENTRYPOINTS = map { $_ => 1 } qw(sdk-cli sdk-ts sdk-py);

sub build {
    my (%a) = @_;
    my @tags;
    push @tags, 'midturn' if $a{midturn};
    push @tags, 'nonok' if $a{nonok};
    # step 4 is two tagged lines: exactly one prod tag, prod-allow only when
    # this helper's own unattended_prod_reads (settings file only) is allow. The classic path has
    # no idle signal at SessionStart, so it never pushes idle (never with midturn).
    my $prod = eval { settings::prod(rc::settings()) };
    push @tags, (($prod && ($prod->{reads} // '') eq 'allow') ? 'prod-allow' : 'prod-forbid');
    # @store@ (line 1 of the text defines <store>): the launcher word that
    # handoff_turn::finish_command stands for, as the mod's storeRuntime fills it. A root no
    # quoting can carry (store_path_unquotable) has no word: drop the lines that hold the token.
    my $store = ctx::store_cmd();
    my $re = $a{remeasure} // '';
    # GSD re-entry per session: the re-enter line only beside a measured driver
    # (never with [idle-halt], which this classic path never sets).
    push @tags, 'driver' if $re =~ /^Active driver: /m;
    # In auto permission mode the classifier blocks a gated outward action
    # a carried approval covers (0.1.4: destructive git and external writes; a plain push
    # passes), so [auto-mode] asks first. The mode is the newest main Stop's,
    # which on_Stop already keeps (restart::note_stop); no new probe.
    push @tags, 'auto-mode' if auto_mode(rc::sid_dir());
    # 0.1.3: one fixed first line before any tool call (no handoff ack or idle-again
    # here); 0.1.4: not when a script reads the reply.
    push @tags, 'resumed' unless script_reader();
    my $max = 3000;
    my $text;
    for (1 .. 12) {
        $text = assemble::asset('res', \@tags, { session_id => $a{sid}, saved_copy => $a{saved_copy},
                                                  measured_at => $a{measured_at} // util::iso(util::now()),
                                                  remeasure => $re, resume_line => $RESUMED_FALLBACK,
                                                  (defined $store ? (store => $store) : ()) },
                                defined $store ? [] : ['store']);
        last if length($text) <= $MAX_CHARS;
        $max -= 400;
        last if $max < 200;
        $re = measure::cap([split /\n/, $re], $max);
    }
    rc::emit('resume_block_over_soft', [nonce => $a{nonce}, chars => length($text)]) if length($text) > $SOFT_CHARS;
    return $text;
}

# script_reader() -> 1 when a script reads this session's reply, so the block has no [resumed]
# line (0.1.4, as the mod's resume.ts scriptReader): CLAUDE_CODE_ENTRYPOINT, which Claude Code
# sets for the hooks it runs, names `claude -p` or the Agent SDK (%SCRIPT_ENTRYPOINTS); any other
# value (cli, claude-desktop, claude-vscode: a person reads the reply) keeps the line. Unset (an older
# Claude Code, a host that does not set it): 1 when the mod logged this session headless (its
# `headless` row: session.start said no person is at the prompt, or a compaction call was refused
# as headless), else the line stays.
sub script_reader {
    my $ep = $ENV{CLAUDE_CODE_ENTRYPOINT};
    return $SCRIPT_ENTRYPOINTS{$ep} ? 1 : 0 if defined $ep && $ep ne '';
    my $rows = eval { rollup::stream_rows(rc::stream_path('mod'), evs => ['headless']) } || [];
    return (grep { ($_->{ev} // '') eq 'headless' } @$rows) ? 1 : 0;
}

# auto_mode(sid_dir) -> 1 when the newest main Stop of this session ran in auto permission mode.
sub auto_mode {
    my ($d) = @_;
    my $m = eval { restart::read_mode($d)->{stop_mode} };
    return (defined $m && $m eq 'auto') ? 1 : 0;
}

sub pending_line {
    return 'pending (saved after this message; /' . ctx::brand() . ':status shows the path)';
}

# claim(sid, nonce, channel, bytes => n, nonok_note => bool) -> ('CLAIMED') | ('TAKEN', channel) | ('REFUSED', why)
# Exclusive create of <watch>/<sid>/resume-claimed/<nonce>, content = channel; row resume_inject.
our %CHANNELS = map { $_ => 1 } qw(sessionstart prompt.context prompt.submit);

sub claim {
    my ($sid, $nonce, $channel, %o) = @_;
    my $d = rc::sid_dir() // return ('REFUSED', 'no-watch');
    my $f = "$d/resume-claimed/$nonce";
    util::mkdir_p("$d/resume-claimed");
    if (util::write_excl($f, "$channel\n", 0600)) {
        rc::emit('resume_inject', [nonce => $nonce, channel => $channel, bytes => $o{bytes}, nonok_note => $o{nonok_note}]);
        return ('CLAIMED');
    }
    # The winner creates the file, then writes its channel: a loser that reads in
    # between sees it empty, so wait briefly for the content (up to ~0.5 s).
    my $who;
    for my $try (1 .. 50) {
        my $raw = util::read_file($f) // '';
        ($who) = $raw =~ /^(\S+)/;
        last if defined $who;
        util::sleep_ms(10);
    }
    return ('TAKEN', $who // 'unknown');
}

# arm(sid_dir, sid) -> the armed nonce, or undef (AT-RP-04).
# SessionStart with source=resume: the mod's record of a block still pending for this session
# id (<sid_dir>/resume-pending.json, written at its compaction) becomes resume-armed.json by one
# rename, so one process wins it. The mod's first prompt.context of this session id delivers it
# (claim, 600 s re-measure rule, settle). Nothing is armed for a record of another session id, a
# settled or malformed one, a symlink, or one whose nonce is claimed already, and nothing while
# another process of this session id still runs (a copy started with `--resume <id>` beside the
# original: the original keeps its block). An armed record that no turn took yet stays armed for
# the next resume; the first turn end of a process settles it (settle_armed).
sub arm {
    my ($d, $sid) = @_;
    return undef unless defined $d && defined $sid;
    my $f = "$d/resume-pending.json";
    return undef if -l $f || !-f _;
    my $j = _record($f) // return undef;
    return undef unless ($j->{state} // '') eq 'pending';
    return undef unless defined $j->{session_id} && !ref $j->{session_id} && $j->{session_id} eq $sid;
    my $nonce = $j->{nonce};
    return undef unless !ref $nonce && nonce::valid($nonce);
    return undef if -e "$d/resume-claimed/$nonce";
    return undef if -l "$d/resume-armed.json";
    return undef if _other_live($sid);
    rename($f, "$d/resume-armed.json") or return undef;
    return $nonce;
}

# settle_armed(sid_dir, sid) -> the settled nonce, or undef. At a main Stop: the first turn of
# this process has ended, so an armed record still pending was not taken by it (the mod's
# prompt.context ran before the arm, or no mod is loaded) and is never delivered to a later turn
# or process. It is rewritten as settled, without the block: `delivered:<channel>` when its nonce
# is claimed, else `undelivered`. The mod's own settle writes its `mod_outcome` row; this one
# writes none.
sub settle_armed {
    my ($d, $sid) = @_;
    return undef unless defined $d && defined $sid;
    my $f = "$d/resume-armed.json";
    return undef if -l $f || !-f _;
    my $j = _record($f) // return undef;
    return undef unless ($j->{state} // '') eq 'pending';
    my $nonce = $j->{nonce};
    return undef unless defined $nonce && !ref $nonce && nonce::valid($nonce);
    my ($who) = (util::read_file("$d/resume-claimed/$nonce") // '') =~ /^([a-z.]+)/;
    my $resume = -e "$d/resume-claimed/$nonce" ? 'delivered:' . ($who // 'unknown') : 'undelivered';
    util::write_atomic($f, jsonc::encode_bytes(jsonc::obj(v => 1, state => 'settled', session_id => $sid, nonce => $nonce,
                                                          resume => $resume, ts => util::iso(util::now()))) . "\n", 0600);
    return $nonce;
}

# waits(sid_dir, nonce) -> 1 when this nonce's block still waits for a turn: no claim, and the
# mod's record of it (resume-pending.json, or resume-armed.json once a resume armed it) is still
# pending. A settle (delivered, replaced by a newer compaction, undelivered, dropped by /clear)
# rewrites the record, so the block no longer waits. The watcher's A-23 hold reads the same files
# (lib/watch/rules.pm `_block_waits`).
sub waits {
    my ($d, $nonce) = @_;
    return 0 unless defined $d && defined $nonce && !ref $nonce && nonce::valid($nonce);
    return 0 if -e "$d/resume-claimed/$nonce";
    for my $f (qw(resume-pending.json resume-armed.json)) {
        next if -l "$d/$f" || !-f "$d/$f";
        my $j = _record("$d/$f") // next;
        return 1 if ($j->{state} // '') eq 'pending' && ($j->{nonce} // '') eq $nonce;
    }
    return 0;
}

sub _record {
    my ($f) = @_;
    my $raw = util::read_file($f, 1024 * 1024) // return undef;
    my $j = eval { jsonc::decode($raw) };
    return ref $j eq 'HASH' && ($j->{v} // 0) eq '1' ? $j : undef;
}

# Another process of this session id still runs: a per-process record of sid, not this
# process's, with no ended- twin, that counts as live (sessions::record_live: a pid gone or
# started again counts as ended; an in-place restart keeps the pid and start time, so it is this
# process).
sub _other_live {
    my ($sid) = @_;
    return 0 unless rc::root_ok('handoff_root');
    my $c = rc::claude();
    my $me = ref $c eq 'HASH' && defined $c->{pid} ? sessions::_key($c) : '';
    return scalar grep { $_->{_key} ne $me && sessions::record_live($_) } @{ sessions::records_for($sid)->{live} || [] };
}

1;

package resumeblock;
# lib/resumeblock.pm: the post-compaction resume block (MOD-SPEC §3.4):
# resume-context.txt with [midturn]/[nonok], exactly one of [prod-forbid]/[prod-allow], and
# [driver] when the re-measure names this session's Active driver (lib/gsd.pm; owner 2026-10-26),
# @session_id@, @saved_copy@, @measured_at@, @remeasure@ (<= 3,000 B), @store@ (C-5). Total soft
# 6,500 chars (compaction-rem-6; soft since the owner overturned ratify xxxxxxxx#R3 on 2026-10-23,
# SPEC-DELTAS RP-2): a block over it logs resume_block_over_soft {nonce, chars}. Hard runtime cap
# 9,500 chars, under the 10,000-char SessionStart cutoff: over it the measured block is cut first,
# at a line boundary. No transcript path.
# Owner: WP-core.
use strict;
use warnings;
use utf8;

our $MAX_CHARS = 9500;
our $SOFT_CHARS = 6500;

sub build {
    my (%a) = @_;
    my @tags;
    push @tags, 'midturn' if $a{midturn};
    push @tags, 'nonok' if $a{nonok};
    # step 4 is two tagged lines (S-SETTINGS B, XR-19): exactly one prod tag, prod-allow only when
    # this helper's own unattended_prod_reads (settings file only) is allow. The classic path has
    # no idle signal at SessionStart, so it never pushes idle (never with midturn).
    my $prod = eval { settings::prod(rc::settings()) };
    push @tags, (($prod && ($prod->{reads} // '') eq 'allow') ? 'prod-allow' : 'prod-forbid');
    # @store@ (TXT-06 line 1 defines <store>; PKG-RUNTIME A.2): the launcher word that
    # handoff_turn::finish_command stands for, as the mod's storeRuntime fills it. A root no
    # quoting can carry (store_path_unquotable) has no word: drop the lines that hold the token.
    my $store = ctx::store_cmd();
    my $re = $a{remeasure} // '';
    # Owner 2026-10-26 (GSD re-entry per session): the re-enter line only beside a measured driver
    # (never with [idle-halt], which this classic path never sets).
    push @tags, 'driver' if $re =~ /^Active driver: /m;
    my $max = 3000;
    my $text;
    for (1 .. 12) {
        $text = assemble::asset('res', \@tags, { session_id => $a{sid}, saved_copy => $a{saved_copy},
                                                  measured_at => $a{measured_at} // util::iso(util::now()),
                                                  remeasure => $re, (defined $store ? (store => $store) : ()) },
                                defined $store ? [] : ['store']);
        last if length($text) <= $MAX_CHARS;
        $max -= 400;
        last if $max < 200;
        $re = measure::cap([split /\n/, $re], $max);
    }
    rc::emit('resume_block_over_soft', [nonce => $a{nonce}, chars => length($text)]) if length($text) > $SOFT_CHARS;
    return $text;
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

# arm(sid_dir, sid) -> the armed nonce, or undef (owner 2026-10-27 "Fix in 0.1.1", AT-RP-04).
# SessionStart with source=resume: the mod's record of a block still pending for this session
# id (<sid_dir>/resume-pending.json, written at its compaction) becomes resume-armed.json by one
# rename, so one process wins it. The mod's first prompt.context of this session id delivers it
# (claim, 600 s re-measure rule, settle). Nothing is armed for a record of another session id, a
# settled or malformed one, a symlink, or one whose nonce is claimed already. An armed record
# that no turn took yet stays armed for the next resume.
sub arm {
    my ($d, $sid) = @_;
    return undef unless defined $d && defined $sid;
    my $f = "$d/resume-pending.json";
    return undef if -l $f || !-f _;
    my $raw = util::read_file($f, 1024 * 1024) // return undef;
    my $j = eval { jsonc::decode($raw) };
    return undef unless ref $j eq 'HASH' && ($j->{v} // 0) eq '1' && ($j->{state} // '') eq 'pending';
    return undef unless defined $j->{session_id} && !ref $j->{session_id} && $j->{session_id} eq $sid;
    my $nonce = $j->{nonce};
    return undef unless !ref $nonce && nonce::valid($nonce);
    return undef if -e "$d/resume-claimed/$nonce";
    return undef if -l "$d/resume-armed.json";
    rename($f, "$d/resume-armed.json") or return undef;
    return $nonce;
}

1;

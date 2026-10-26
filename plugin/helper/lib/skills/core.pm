package skills::core;
# lib/skills/core.pm: the one place where WP-skills calls WP-core's library
# seams (BUILD-PLAN §3.6). Every assumption about a seam's argument or return
# shape is normalised here, so integration changes this file only.
#
# Assumed shapes (provisional until WP-core's code lands):
#   settings::resolve(\%flags)        -> hashref of userConfig keys (MOD §1.2) with the
#                                        effective values; optional {_source}{key}
#   paths::for($settings, $sid)        -> {root, watch, disposable}
#   roots::check($settings)            -> 'ok' | {ok=>1} | undef (ok); a string reason
#                                        or {refused=>reason} (refused)
#   log::row($ev, \%fields, \%ctx)     -> row (hashref or JSON line)
#   log::append($file, $row)           -> appends to the absolute stream file
#   lock::with($path, \%owner, $fn)    -> $fn's return; dies when the lock is live
#   identity::claude_pid()             -> {pid, lstart}
#   identity::start_time($pid)         -> start time in the record format, or undef
#   nonce::draw($sid)                  -> 8 lowercase hex
#   secrets::scan($text)               -> [{rule, class}]
#   secrets::classify_file($path)      -> (copy | redact | withhold, [{rule, class}])
#   secrets::redact($text)             -> ($redacted_text, [{rule, class}]) over every rule class
#   evidence::copy($src,$dir,\%caps,$index) -> {status, copy, bytes, sha256, mtime, scan, rules}
#   gsd::read($worktree)               -> arrayref of lines | {lines=>[...]} | undef
#   queue::call(\@argv, $budget_ms)    -> {rc|exit, out|stdout, timed_out|timeout}
#   queue::lane($sid, $cmd, $budget_ms) -> {status => ok|off|unknown|timeout, why, lane, open,
#                                        ids, label, queued_line}: the one `list --json` parser
#                                        (Q-ADAPTER QA-1; CORE-18 makes the queue-stub/v1 tag
#                                        required: why untagged|schema)
#   queue::caps_get($cmd)              -> {commands => [..]|undef, listed, add}
#   queue::mode($cmd)                  -> {mode => off|on|degraded, why} with no queue call (CORE-18)
#   queue::must_exist($cmd)            -> 1 when the cached commands hold adopt:must-exist (CORE-18)
#   bucket::resolve($sid, $cwd, $topic, $settings) -> {path, source}; path absolute
#                                        (<root>/<repo>/<bucket>); settings passed as a 4th
#                                        argument because a skill flag can move the root
#   detect::summary($text)             -> {verdict, marker_line, sentinel_from_end, nonce, scope}
# Seams of the 2026-10-21 rulings (needs/core-to-skills.md):
#   rc::sid_dir(), rc::mode($cwd)      -> <watch>/<sid>; the D-12 mode record (repomode::decide)
#   handoff_turn::open_for_begin / bind_stage / stage_of / mark_published / record (D-18 B7, B8)
#   sidecar::newest($sid_dir)          -> the slot of the highest seq (DP-13)
#   transcript::quotes_found($path, [{quote, targets}], $sid, since => $epoch) -> [1|0|undef…] | undef (AP-4)
#   sessions::own_start($sid)          -> {since, until, coarse} from the session's per-process
#                                        records | undef (review of bcdaca6: coarse = no milliseconds)
#   sessions::ended($sid)              -> 1 when no per-process record of sid is live (handoff-resume link)
#   detect::alias_scan($text, $name)   -> scan() under a former plugin name (owner xxxxxxxx-26)
#   jobrec::record_of / read_rows / jobs_path / add_pending (Dev-1)
#   settings::relaunch($resolved)      -> {auto, allow, quiet_s, allow_active, invalid, clamped}
#   settings::protected($resolved)     -> {globs => [{id, re}], user, invalid} (owner xxxxxxxx-29)
#   settings::protected_user($name, $p) -> the id of the user's entry naming the branch | undef
use strict;
use warnings;
use utf8;
use POSIX ();
use skills::util;
use settings;
use paths;
use roots;
use log;
use lock;
use identity;
use nonce;
use secrets;
use evidence;
use gsd;
use queue;
use bucket;
use detect;
use rc;
use repomode;
use handoff_turn;
use sidecar;
use jobrec;

sub settings {
    my ($flags) = @_;
    # The core libraries read the run context (rc: root, watch, root checks, the row
    # envelope). A skill flag can move the roots, so the context is built from the flags.
    my $r = rc::init(sid => 'unknown', writer => 'helper', actor => 'main', flags => $flags || {});
    my $s = ref $r eq 'HASH' ? $r->{settings} : undef;
    $s = $s->{values} if ref $s eq 'HASH' && ref $s->{values} eq 'HASH';
    die "settings: no result\n" unless ref $s eq 'HASH';
    return skills::util::text_deep($s);
}

# The session id the core context logs and locks under (rc), once a skill knows it.
sub bind_sid {
    my ($sid) = @_;
    rc::set_sid($sid) if defined $sid && $sid ne '' && defined &rc::set_sid;
    return $sid;
}

sub paths {
    my ($s, $sid) = @_;
    my $p = paths::for($s, $sid);
    die "paths: no result\n" unless ref $p eq 'HASH' && $p->{root};
    return skills::util::text_deep($p);
}

# undef when the roots are safe, else the refusal reason.
sub roots_check {
    my ($s) = @_;
    my $r = skills::util::text_deep(roots::check($s));
    return undef if !defined $r;
    if (ref $r eq 'HASH') {
        return undef if $r->{ok};
        # WP-core shape: one result per root key, {ok} or {ok => 0, reason}. The skills
        # write under handoff_root and disposable_root; log_dir falls back in core.
        my @per = grep { ref $r->{$_} eq 'HASH' } qw(handoff_root disposable_root);
        if (@per) {
            for my $k (@per) { return $r->{$k}{reason} // 'root-unsafe' unless $r->{$k}{ok} }
            return undef;
        }
        return $r->{refused} // $r->{reason} // 'root-unsafe';
    }
    return undef if $r eq 'ok' || $r eq '1';
    $r =~ s/\AREFUSED:\s*//;
    $r =~ s/\Arefused\((.*)\)\z/$1/;
    return $r;
}

# One content-free row to <watch>/<sid>.classic.jsonl.
sub log_event {
    my ($ctx, $ev, $fields) = @_;
    my $sid = $ctx->{sid} // 'unknown';
    my $file = "$ctx->{watch}/$sid.classic.jsonl";
    my %c = (
        sid            => $sid,
        actor          => $ctx->{actor} // 'main',
        writer         => 'helper',
        pid            => $$,
        plugin_version => $ctx->{version},
        cc_version     => undef,
        turn_seq       => undef,
    );
    eval {
        skills::util::mkdir_p($ctx->{watch});
        my $row = log::row($ev, $fields || {}, \%c);
        log::append($file, $row);
        1;
    } or return 0;
    return 1;
}

sub host { my @u = POSIX::uname(); return $u[1] // 'unknown' }

sub lock_owner {
    my ($sid, $actor) = @_;
    return { sid => $sid, actor => $actor // 'main', pid => $$, lstart => lstart($$), host => host() };
}

# Returns ($ok, $value_or_error).
sub with_lock {
    my ($path, $owner, $fn) = @_;
    my @r;
    my $ok = eval { @r = lock::with($path, $owner, $fn); 1 };
    return (0, ($@ || 'lock') =~ s/\s+\z//r) unless $ok;
    return (1, $r[0]);
}

sub claude_pid {
    my $r = eval { identity::claude_pid() };
    return undef unless ref $r eq 'HASH' && $r->{pid};
    return $r;
}

# Start time of any pid, in the format the per-process records carry: identity::start_time
# only (/proc on Linux, else `ps -o lstart=` under LC_ALL=C), never a second `ps` read, so a
# Linux image without ps reads the same start time the records hold.
sub lstart {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /\A\d+\z/;
    my $v = eval { identity::start_time($pid) };
    return defined $v && $v ne '' ? $v : undef;
}

sub nonce {
    my ($sid) = @_;
    my $n = nonce::draw($sid);
    die "nonce: bad value\n" unless defined $n && $n =~ /\A[0-9a-f]{8}\z/;
    return $n;
}

# AP-4: the writing session's human-typed rows, or the user's answers in its AskUserQuestion
# dialogs (NR-14), hold each quote (in memory; nothing logged).
# $sid: only rows this session wrote after it started count (owner 2026-10-23 xxxxxxxx-27
# revised, "No: forks re-ask"; REVIEW-NIGHT-3 R3-03): another session's id, forkedFrom, or a time
# before the session's first per-process record (sessions::own_start) is a copy; a record without
# milliseconds leaves its own second to the row-order rule (transcript.pm "Coarse start"). No
# record: undef (not checked; the line is published unchecked and the next session re-asks).
# after => epoch: a later floor (a successor's claim on this session, root reading 2026-10-23).
sub quotes_found {
    my ($path, $asks, $sid, %o) = @_;
    return undef unless defined &transcript::quotes_found && defined &sessions::own_start;
    my $s = eval { sessions::own_start($sid) };
    return undef unless ref $s eq 'HASH' && defined $s->{since};
    my %w = (since => $s->{since}, ($s->{coarse} ? (coarse => 1, until => $s->{until}) : ()));
    # `after` (skills::approvals::quote_floor, a successor's claim on this session): only rows at
    # or after it count, and a coarse start's order-only window ends there too (fail closed).
    if (defined $o{after} && $o{after} > $s->{since}) {
        my $f = $s->{coarse} && $s->{until} > $o{after} ? $s->{until} : $o{after};
        %w = (since => $f);
    }
    my $r = transcript::quotes_found($path, $asks, $sid, %w);
    return ref $r eq 'ARRAY' ? $r : undef;
}

# The plugin's former names (settings.pm @FORMER_NAMES, the current brand excluded): a marker
# under one of them is the read-only alias of owner ruling xxxxxxxx-26.
sub former_names {
    my $brand = eval { ctx::brand() } // '';
    return grep { defined && !ref && /\A[a-z0-9][a-z0-9-]{0,63}\z/ && $_ ne $brand } @settings::FORMER_NAMES;
}

# detect_former(text) -> {name, marker_line, sentinel_from_end, nonce, sentinel_nonce, scope} |
# undef: the first former name whose marker (first 5 body lines) and sentinel (last 3) both
# match with one nonce (detect::alias_scan).
sub detect_former {
    my ($text) = @_;
    return undef unless defined &detect::alias_scan;
    for my $n (former_names()) {
        my $s = eval { detect::alias_scan($text, $n) };
        next unless ref $s eq 'HASH' && defined $s->{nonce} && defined $s->{sentinel_nonce} && $s->{sentinel_nonce} eq $s->{nonce};
        return skills::util::text_deep({ name => $n, marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end},
                                         nonce => $s->{nonce}, sentinel_nonce => $s->{sentinel_nonce}, scope => $s->{scope} });
    }
    return undef;
}

# session_ended(sid) -> 1 when every per-process record of sid has ended (sessions::ended: an
# ended- twin, or on this host a pid that is gone or runs with another start time); 0 when one is
# live, the session has no record, or the seam fails (fail closed).
sub session_ended {
    my ($sid) = @_;
    return 0 unless defined &sessions::ended;
    my $r = eval { sessions::ended($sid) };
    return $r ? 1 : 0;
}

sub secrets_scan {
    my ($text) = @_;
    my $r = secrets::scan($text);
    return [] unless ref $r eq 'ARRAY';
    return [ map { { rule => $_->{rule} // $_->{id} // 'unknown', class => uc($_->{class} // 'WARN') } } @$r ];
}

sub classify_file {
    my ($path) = @_;
    my ($r) = classify_file_hits($path);
    return $r;
}

# (copy|redact|withhold, [{rule, class}], $scanned): the gate's verdict, its hits (ids,
# never values) and, for copy and redact, the bytes the gate scanned (RRP-06: write those,
# never a second read of the file).
sub classify_file_hits {
    my ($path) = @_;
    my ($r, $hits, $raw) = secrets::classify_file($path);    # WP-core returns (action, \@hits, bytes)
    $r = $r->{action} // $r->{class} if ref $r eq 'HASH';
    return ($r // 'copy', _hits($hits), $raw);
}

# A path the name gate refuses: deny-listed by name, or never copied (transcripts, session
# JSONL, environment dumps); the path and its real target are both checked.
sub denied_path {
    my ($path) = @_;
    return (secrets::denied_name($path) || secrets::never_copy($path)) ? 1 : 0;
}

# (text with each hit replaced by [redacted:<rule>], [{rule, class}]), every rule class.
sub secrets_redact {
    my ($text) = @_;
    my ($red, $hits) = secrets::redact($text);
    die "secrets: redact gave no text\n" unless defined $red;
    return ($red, _hits($hits));
}

sub _hits {
    my ($h) = @_;
    return [] unless ref $h eq 'ARRAY';
    return [ map { { rule => $_->{rule} // $_->{id} // 'unknown', class => uc($_->{class} // 'WARN') } } @$h ];
}

sub evidence_copy {
    my ($src, $dir, $caps, $index) = @_;
    # WP-core keeps the running total behind a scalar ref (caps.used => \$bytes).
    my %c = %{ $caps || {} };
    $c{used} = \(my $u = $c{used} // 0) unless ref $c{used};
    # The skill writes MANIFEST.tsv itself at publish (exclusive create), and its ref-only
    # rows carry no copy (`ref-only - <bytes> <sha8> <origin>`, handoff SKILL Step 4).
    $c{manifest} //= 0;
    $c{ref_file} //= 0;
    my $r = evidence::copy($src, $dir, \%c, $index);
    die "evidence: no row\n" unless ref $r eq 'HASH';
    $r->{status} //= $r->{result} // 'missing';
    $r->{copy}   //= $r->{copy_path} // $r->{path};
    # WP-core does not hash a file withheld by name; the skill's rows and MANIFEST carry
    # its sha256 (a hash, never content).
    $r->{sha256} //= sha::hex256_file($src) if $r->{status} eq 'withheld' && -f $src;
    $r->{sha256} //= '';
    $r->{bytes}  //= 0;
    $r->{scan}   //= $r->{status} eq 'copied' ? 'full' : $r->{status};
    return skills::util::text_deep($r);
}

sub gsd {
    my ($wt) = @_;
    my $r = eval { gsd::read($wt) };
    return undef unless defined $r;
    $r = $r->{lines} if ref $r eq 'HASH';
    $r = [ split /\n/, $r ] unless ref $r;
    return undef unless ref $r eq 'ARRAY' && @$r;
    return skills::util::text_deep($r);
}

sub queue_call {
    my ($argv, $budget) = @_;
    skills::util::trace('queue_cmd');
    my $r = eval { queue::call($argv, $budget) };
    return { rc => -1, out => '', timed_out => 0, error => 1 } unless ref $r eq 'HASH';
    return {
        rc        => $r->{rc} // $r->{exit} // -1,
        out       => skills::util::text($r->{out} // $r->{stdout} // ''),
        timed_out => $r->{timed_out} // $r->{timeout} // 0,
    };
}

# ---- queue adapter (Q-ADAPTER QA-1, QA-B2): one parser (queue::lane) for begin; locate
# reads the mode without a queue call (queue_mode_now below).
# Mode: off (queue_cmd empty: no exec, no trace) · degraded (<why>) when the setting is not
# an executable file or the list reply broke the contract (untagged · schema · not-json ·
# exit · timeout) · else on (a reply that keeps the contract but names no usable lane is on).
my %QUEUE_ON_WHY = map { $_ => 1 } qw(no-lane preview auto-empty);

sub queue_lane {
    my ($sid, $cmd, $budget) = @_;
    return { status => 'off' } if skills::util::unset_value($cmd);
    my $r = eval { queue::lane(skills::util::bytes($sid // 'unknown'), skills::util::bytes($cmd), $budget // 5000) };
    return { status => 'unknown', why => 'exit' } unless ref $r eq 'HASH';
    return skills::util::text_deep($r);
}

# {mode => off|on|degraded, why => …} from a queue_lane result.
sub queue_mode {
    my ($l) = @_;
    my $st = (ref $l eq 'HASH' ? $l->{status} : undef) // 'unknown';
    return { mode => 'off' } if $st eq 'off';
    return { mode => 'on' } if $st eq 'ok';
    return { mode => 'degraded', why => 'timeout' } if $st eq 'timeout';
    my $why = $l->{why} // 'exit';
    return { mode => 'on' } if $QUEUE_ON_WHY{$why};
    return { mode => 'degraded', why => $why };
}

# {mode => off|on|degraded, why => …} without running the queue tool (locate, QA-1): WP-core's
# queue::mode($cmd) (CORE-18: the setting, the file, and this session's last list outcome, so
# a broken reply that begin saw shows as degraded (<why>) here too). No exec, no queue_cmd
# trace, no caps-cache write. Without that seam (or when it fails or answers another shape):
# the setting alone (queue_mode_setting).
my %QUEUE_MODES = map { $_ => 1 } qw(off on degraded);
sub queue_mode_now {
    my ($cmd) = @_;
    return { mode => 'off' } if skills::util::unset_value($cmd);
    my $m = defined &queue::mode ? eval { queue::mode(skills::util::bytes($cmd)) } : undef;
    if (ref $m eq 'HASH' && defined $m->{mode} && $QUEUE_MODES{ $m->{mode} }
        && ($m->{mode} ne 'degraded' || (defined $m->{why} && !ref $m->{why} && $m->{why} =~ /\A[a-z-]{1,32}\z/))) {
        return skills::util::text_deep({ mode => $m->{mode}, ($m->{mode} eq 'degraded' ? (why => $m->{why}) : ()) });
    }
    return queue_mode_setting($cmd);
}

# The setting alone: off when queue_cmd is empty, degraded (not-executable) when it is not an
# executable file, else on (the fallback of queue_mode_now).
sub queue_mode_setting {
    my ($cmd) = @_;
    return { mode => 'off' } if skills::util::unset_value($cmd);
    my $b = skills::util::bytes($cmd);
    return { mode => 'degraded', why => 'not-executable' } unless -f $b && -x _;
    return { mode => 'on' };
}

# `off`, `on` or `degraded (<why>)`: the form begin's queue line, locate and /status print.
sub queue_mode_text {
    my ($m) = @_;
    return $m->{mode} eq 'degraded' ? "degraded ($m->{why})" : $m->{mode};
}

# The cached `commands` of the last list reply for this queue_cmd file ([] when none).
sub queue_commands {
    my ($cmd) = @_;
    my $c = eval { queue::caps_get(skills::util::bytes($cmd)) };
    return (ref $c eq 'HASH' && ref $c->{commands} eq 'ARRAY') ? skills::util::text_deep($c->{commands}) : [];
}

# 1 when `lane adopt` passes --must-exist (QA-2): WP-core's queue::must_exist($cmd) (CORE-18),
# else the same test over the cached commands (queue_commands).
sub queue_must_exist {
    my ($cmd) = @_;
    if (defined &queue::must_exist) {
        my $r = eval { queue::must_exist(skills::util::bytes($cmd)) };
        return $r ? 1 : 0 if defined $r;
    }
    return (grep { $_ eq 'adopt:must-exist' } @{ queue_commands($cmd) }) ? 1 : 0;
}

sub bucket_resolve {
    my ($sid, $cwd, $topic, $s) = @_;
    # WP-core: resolve(sid, cwd, topic [, where]) reads the root from the run context,
    # which settings() built from the same flags; the 4th argument is git facts, not settings.
    my $r = bucket::resolve($sid, $cwd, $topic);
    die "bucket: no result\n" unless ref $r eq 'HASH' && $r->{path};
    return skills::util::text_deep($r);
}

# ---------------------------------------------------------------- 2026-10-21 seams

# The effective watch dir (log_dir, or its safe default), or undef when neither is safe.
sub watch_dir { my $w = eval { rc::watch() }; return skills::util::text($w) }

# <watch>/<sid> of the bound session (the effective watch dir: log_dir, or its safe default).
sub sid_dir { my $d = eval { rc::sid_dir() }; return skills::util::text($d) }

# The D-12 mode of cwd's worktree: {mode, reason, toplevel, main_checkout, root_rel, root_path,
# ignored, exports, ...}; rc::mode logs handoff_mode once per (mode, reason).
sub mode {
    my ($cwd) = @_;
    my $m = eval { rc::mode($cwd) };
    return { mode => 'private', reason => 'repo-root-unchecked' } unless ref $m eq 'HASH' && $m->{mode};
    return skills::util::text_deep($m);
}

# A worktree's declaration and repository-root check (D-12 §1.5.2, §1.5.3), read-only.
sub declaration { my ($top) = @_; my $d = eval { repomode::declaration($top) }; return ref $d eq 'HASH' ? skills::util::text_deep($d) : { present => 0 } }
sub repo_check  { my ($top, $root) = @_; my $c = eval { roots::repo_check($top, $root) }; return ref $c eq 'HASH' ? skills::util::text_deep($c) : { ok => 0, reason => 'repo-root-unchecked' } }
sub gitignore_text { return repomode::gitignore_text() }
sub default_root { return $repomode::DEFAULT_ROOT }
sub decl_name { return $repomode::DECL }
sub valid_root { return repomode::valid_root($_[0]) }

# The handoff-turn store (D-18), all read through lib/handoff_turn.pm.
sub ht_open_for_begin { my ($d) = @_; return defined $d ? skills::util::text_deep(handoff_turn::open_for_begin($d)) : undef }
sub ht_stage_of       { my ($d, $ht) = @_; return defined $d ? skills::util::text(handoff_turn::stage_of($d, $ht)) : undef }
sub ht_bind_stage     { my ($d, $ht, $stage) = @_; return map { skills::util::text_deep($_) } handoff_turn::bind_stage($d, $ht, $stage) }
sub ht_mark_published { my ($d, $ht, $path) = @_; return map { skills::util::text_deep($_) } handoff_turn::mark_published($d, $ht, $path) }
sub ht_record         { my ($d, $ht) = @_; return defined $d ? skills::util::text_deep(handoff_turn::record($d, $ht)) : undef }
sub ht_published_of   { my ($d, $ht) = @_; return defined $d ? skills::util::text(handoff_turn::published_of($d, $ht)) : undef }
sub ht_valid          { return handoff_turn::valid_ht($_[0]) }

# (slot object, slot path) of the highest seq in <sid_dir>/bg, or (): the rule of
# sidecar::newest (DP-13: by seq, never by mtime; the first of equal seqs in name order).
sub sidecar_newest {
    my ($sid_dir) = @_;
    return () unless defined $sid_dir && -d "$sid_dir/bg";
    my ($best, $path);
    for my $f (skills::util::list_dir("$sid_dir/bg")) {
        next unless $f =~ /\Aslot-\d+\.json\z/;
        my $d = eval { skills::util::json_decode(skills::util::read_file("$sid_dir/bg/$f", 262144)) };
        next unless ref $d eq 'HASH';
        ($best, $path) = ($d, "$sid_dir/bg/$f") if !$best || ($d->{seq} // 0) > ($best->{seq} // 0);
    }
    return $best ? ($best, $path) : ();
}

# Dev-1 job records of a session dir.
sub job_record { my ($sid_dir, $task) = @_; return skills::util::text_deep(eval { jobrec::record_of($sid_dir, $task) }) }
sub job_rows   { my ($sid_dir) = @_; my $r = eval { jobrec::read_rows(jobrec::jobs_path($sid_dir)) }; return ref $r eq 'ARRAY' ? skills::util::text_deep($r) : [] }
sub job_add_pending { my ($sid_dir, $p) = @_; return jobrec::add_pending($sid_dir, $p) }
sub job_output_source { return $jobrec::OUTPUT_PATH_SOURCE // 'none' }

# CR-F8: the one-line form of a recorded command, as a recipe's `command:` line holds it
# (line breaks become one space each run, outer blanks trimmed). publish writes this form,
# and heal-check and the lint compare a recipe line with this form of the record; the run
# line itself is always the record, byte for byte (Dev-1 D5).
sub recipe_command {
    my ($c) = @_;
    return undef unless defined $c;
    $c =~ s/[\r\n]+/ /g;
    $c =~ s/\A[ \t]+//;
    $c =~ s/[ \t]+\z//;
    return $c;
}

# settings::relaunch over the run context's resolved settings (consent keys: file only).
sub relaunch {
    my $r = eval { settings::relaunch(rc::settings()) };
    return ref $r eq 'HASH' ? skills::util::text_deep($r) : { auto => 'off', allow => [], quiet_s => 120, allow_active => 0, invalid => [], clamped => [] };
}

# The run context's settings notes for the given keys (`<key>: settings file only`, the
# CR-F34 safe-value notes), so a command can say why a flag or env value did not count.
sub settings_notes {
    my (@keys) = @_;
    my %want = map { $_ => 1 } @keys;
    my $r = eval { rc::settings() };
    my @n = ref $r eq 'HASH' && ref $r->{notes} eq 'ARRAY' ? @{ $r->{notes} } : ();
    return map { skills::util::text($_) } grep { /\A([a-z_]+):/ && $want{$1} } @n;
}

# Production (S-SETTINGS B): settings::prod over the run context's resolved settings (WP-core,
# CORE-02): {reads => forbid|allow, classes => [{id, re}], user => n, invalid => [..]}, the
# consent key `unattended_prod_reads` read from the settings file only (DP-3) and the classes
# the shipped prod_classes plus the user's prod_patterns. Without that seam (or when it fails):
# forbid, and the shipped classes (the spec's prod_classes, else the same prod-token literal
# core falls back to), so a missing seam never makes the plugin ask less.
our @PROD_FALLBACK = ({ id => 'prod-token', re => '(^|[^A-Za-z0-9])([Pp][Rr][Oo][Dd]|[Pp][Rr][Oo][Dd][Uu][Cc][Tt][Ii][Oo][Nn]|[Pp][Rr][Dd])([^A-Za-z0-9]|$)' });
sub prod {
    my $r = defined &settings::prod ? eval { settings::prod(rc::settings()) } : undef;
    if (ref $r eq 'HASH' && ref $r->{classes} eq 'ARRAY' && @{ $r->{classes} }) {
        my %p = %$r;
        $p{reads} = ($p{reads} // '') eq 'allow' ? 'allow' : 'forbid';
        $p{user} //= scalar grep { ref $_ eq 'HASH' && ($_->{id} // '') =~ /\Auser-/ } @{ $p{classes} };
        return \%p;
    }
    require skills::spec;
    my $spec = eval { skills::spec::get('prod_classes') };
    my @src = ref $spec eq 'ARRAY' && @$spec ? @$spec : @PROD_FALLBACK;
    my @classes;
    for my $c (@src) {
        next unless ref $c eq 'HASH' && defined $c->{id} && defined $c->{re} && !ref $c->{re};
        my $re = eval { qr/$c->{re}/ } or next;
        push @classes, { id => $c->{id}, re => $re };
    }
    @classes = map { { id => $_->{id}, re => qr/$_->{re}/ } } @PROD_FALLBACK unless @classes;
    return { reads => 'forbid', classes => \@classes, user => 0, invalid => [], seam => 'missing' };
}

# Protected branches (owner xxxxxxxx-29): settings::protected over the run context's resolved
# settings: the user's add-only `protected_branches` entries {globs => [{id, re}], user => n,
# invalid => [..]}. Without that seam (or when it fails): no entries of the user's, while the
# callers' shipped checks (protected_branch_re, the remote default branch) stay as they are, so a
# missing seam never removes a shipped entry.
sub protected {
    my $r = defined &settings::protected ? eval { settings::protected(rc::settings()) } : undef;
    return $r if ref $r eq 'HASH' && ref $r->{globs} eq 'ARRAY';
    return { globs => [], user => 0, invalid => [], seam => 'missing' };
}

# protected_user(name, protected) -> the id of the user's entry that names the branch, else undef.
sub protected_user {
    my ($name, $p) = @_;
    return defined &settings::protected_user ? settings::protected_user($name, $p) : undef;
}

sub detect_summary {
    my ($text) = @_;
    my $r = eval { detect::summary($text) };
    return undef unless ref $r eq 'HASH';
    return skills::util::text_deep($r);
}

1;

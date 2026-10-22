package skills::jobs;
# lib/skills/jobs.pm: re-verification of a lost background shell (Dev-1 D3, D4) for
# `heal-check` and `inventory`. File reads and stat calls only: no sleep, no command from
# the handoff, no network, nothing executed. The job record is the plugin's (Dev-1 D1,
# <watch>/<origin sid>/jobs.jsonl); the handoff recipe only points at it.
#
#   V1 record          a job row for the task; its sha matches its command; the origin
#                      transcript has a Bash tool_use with that command whose result
#                      carries this backgroundTaskId (bounded scan, no content printed);
#                      the runtime's own BackgroundTaskSummary.command sha in the sidecar
#                      agrees when it was kept whole (REVIEW B-16)
#   V2 owner ended     the origin session's process: an ended- record, or the pid gone or
#                      restarted; this process in the same session fails (row 2b), and so
#                      does the same live process under a later session (/clear): shells
#                      survive /clear (DP-24 (c), P-D1-3), so the job may still run
#   V3 in flight       the origin session's newest sidecar slot (by seq) lists the task running
#   V4 no completion   the output file exists and its last 200 bytes hold no active end
#                      marker (spec wait.exit_markers); passes only when a marker is
#                      expected (an active runtime marker, or the command ends with the
#                      end suffix); unmeasured while the output path is unknown (P-D1-6).
#                      A `means: killed` marker (`[killed]`, DP-24 (b)) fails it: KILLED
#   V5 quiet           output mtime <= owner end + 5 s; end unknown: <= now - relaunch_quiet_s
#   V6 no effect yet   no recipe `expected outputs:` path has mtime >= launched_at
#                      (stat only; the recipe's idempotency check is shown, never run)
#   V7 runnable        the recorded cwd exists; the command's first word resolves on
#                      PATH, as a path, or is a shell builtin (stat only)
# Effects class (code-derived, never a score): none (core marked it read-only, no outward
# lint hit, sandbox kept, command kept) · local (an allowlisted relaunch_allow pattern, no
# outward hit, a recipe with expected outputs) · outward (any outward lint hit; an allow
# pattern never overrides it) · unknown (everything else, a missing record included).
# Status: the Dev-1 D4 table, first match wins, except that a recorded stop (row 7) is
# checked before rows 5 and 6, so a job stopped on purpose is never relaunched, and a
# `[killed]` output right after row 1 (KILLED: it asks, never LOST, RUNNING or STOPPED).
# A job of the same live process under a later session (owner state `cleared`, /clear)
# with no end marker is RUNNING: probe it, never relaunch it.
use strict;
use warnings;
use utf8;
use skills::util;
use skills::core;
use skills::ctx;
use skills::spec;

our $TAIL_BYTES = 200;
our $TRANSCRIPT_MAX = 64 * 1024 * 1024;
our $END_SLACK_S = 5;
our @SIGNALS = qw(V1 V2 V3 V4 V5 V6 V7);
our %NAME = (V1 => 'record', V2 => 'owner-ended', V3 => 'in-flight', V4 => 'no-completion', V5 => 'quiet',
             V6 => 'no-effect', V7 => 'runnable');
my %BUILTIN = map { $_ => 1 } qw(cd export source . test [ echo exec set true false : printf eval command env);

# verify(ctx, origin => sid, task => id, recipe => {text…} | undef, relaunch => settings::relaunch,
#        cwd => this helper call's cwd, current => {sid, pid, lstart})
#   -> {record, signals => {V1 => [state, detail]…}, status, confidence, effects, marker_rc,
#       owner_end, run_line, command, cwd, output}
sub verify {
    my ($ctx, %a) = @_;
    my $watch = skills::core::watch_dir() // $ctx->{watch};
    my $odir = "$watch/$a{origin}";
    my $rec = skills::core::job_record($odir, $a{task});
    my @rows = @{ skills::core::job_rows($odir) };
    my $stopped = grep { ($_->{ev} // '') eq 'stop' && ($_->{task_id} // '') eq $a{task} } @rows;
    my %sig;
    my %r = (record => $rec, signals => \%sig);
    my $cmd = $rec ? $rec->{command} : undef;
    $r{command} = $cmd;
    $r{cwd} = $rec ? $rec->{cwd} : undef;

    # V1
    if (!$rec) { $sig{V1} = ['unmeasured', 'no job record'] }
    elsif (defined $cmd && skills::util::sha256_hex($cmd) ne ($rec->{command_sha256} // '')) { $sig{V1} = ['fail', 'command sha differs from its record'] }
    else {
        my $tp = transcript_of($ctx, $a{origin}, $rec);
        my $side = _sidecar_task($odir, $a{task});
        if ($side && defined $side->{command_sha256} && defined $side->{command_chars} && $side->{command_chars} < 1000
            && $side->{command_sha256} ne ($rec->{command_sha256} // '')) {
            $sig{V1} = ['fail', 'the runtime task list names another command'];
        } elsif (!defined $tp) {
            $sig{V1} = ['unmeasured', 'origin transcript not found'];
        } else {
            my $t = transcript_has($tp, $rec->{command_sha256}, $a{task});
            # CR-F12: a miss in a bounded scan of a longer transcript is not measured.
            $sig{V1} = !defined $t ? ['unmeasured', 'transcript unreadable']
                     : $t eq 'partial' ? ['unmeasured', 'no matching Bash call in the scanned tail of the origin transcript']
                     : $t ? ['pass', 'record, sha and transcript agree'] : ['fail', 'no matching Bash call in the origin transcript'];
        }
    }

    # V2
    my $own = owner_state($ctx, $a{origin}, $rec, $a{current});
    $r{owner} = $own;
    $r{owner_end} = $own->{end};
    if ($own->{state} eq 'unknown') { $sig{V2} = ['unmeasured', 'no owner record'] }
    elsif ($own->{state} eq 'unverified') { $sig{V2} = ['unmeasured', 'owner pid alive; its start time could not be checked'] }
    elsif ($own->{state} eq 'ended') { $sig{V2} = ['pass', 'owner ended' . (defined $own->{end} ? ' ' . skills::util::stamp($own->{end}) : ' (time unknown)')] }
    elsif ($own->{state} eq 'this') { $sig{V2} = ['fail', 'owner is this process and session'] }
    elsif ($own->{state} eq 'cleared') { $sig{V2} = ['fail', 'owner process still live after /clear' . (defined $own->{end} ? ' ' . skills::util::stamp($own->{end}) : '')] }
    else { $sig{V2} = ['fail', 'owner session live in another process'] }

    # V3
    my $slot_task = _sidecar_task($odir, $a{task}, 1);
    if (!defined $slot_task) { $sig{V3} = ['unmeasured', 'no sidecar slot'] }
    elsif (!ref $slot_task) { $sig{V3} = ['fail', 'not in the last task list'] }
    elsif (($slot_task->{status} // '') =~ /running|pending/i) { $sig{V3} = ['pass', 'listed running'] }
    else { $sig{V3} = ['fail', 'listed ' . ($slot_task->{status} // 'not running')] }

    # V4, V5
    my $out = $rec ? $rec->{output_path} : undef;
    $r{output} = $out;
    if (!defined $out || $out eq '') {
        $sig{V4} = ['unmeasured', 'no output path (source ' . skills::core::job_output_source() . ')'];
        $sig{V5} = ['unmeasured', 'no output path'];
    } elsif (!-f $out) {
        $sig{V4} = ['unmeasured', 'output file missing'];
        $sig{V5} = ['unmeasured', 'output file missing'];
    } else {
        my ($mrc, $expected, $killed) = exit_marker($out, $cmd);
        if ($killed) { $r{killed} = 1; $sig{V4} = ['fail', 'killed'] }
        elsif (defined $mrc) { $r{marker_rc} = $mrc; $sig{V4} = ['fail', "exit marker rc=$mrc"] }
        elsif ($expected) { $sig{V4} = ['pass', 'no exit marker'] }
        else { $sig{V4} = ['unmeasured', 'no exit marker expected'] }
        my $mt = (stat $out)[9];
        my $now = skills::util::now();
        my $quiet = $a{relaunch}{quiet_s} // 120;
        my $ok = defined $own->{end} ? $mt <= $own->{end} + $END_SLACK_S : $mt <= $now - $quiet;
        $sig{V5} = $ok ? ['pass', 'quiet since ' . skills::util::stamp($mt)] : ['fail', 'written ' . skills::util::stamp($mt)];
    }

    # V6
    my $launched = $rec ? skills::util::iso_to_epoch($rec->{launched_at}) : undef;
    my $outs = $a{recipe} ? expected_outputs($a{recipe}{text}) : undef;
    if (!$rec || !defined $launched) { $sig{V6} = ['unmeasured', 'launch time unknown'] }
    elsif ($outs) {
        my @newer = grep { my @st = stat $_; @st && $st[9] >= $launched } @$outs;
        $sig{V6} = @newer ? ['fail', scalar(@newer) . ' expected output(s) written since the launch'] : ['pass', 'no expected output newer than the launch'];
    } else { $sig{V6} = ['pending-class', 'no recipe'] }

    # V7
    if (!$rec) { $sig{V7} = ['unmeasured', 'no job record'] }
    elsif (!defined $cmd) { $sig{V7} = ['unmeasured', 'command withheld'] }
    elsif (!defined $r{cwd} || !-d $r{cwd}) { $sig{V7} = ['fail', 'cwd missing'] }
    else { $sig{V7} = runnable($cmd, $r{cwd}) ? ['pass', 'cwd and command found'] : ['fail', 'command not found'] }

    # Effects class
    $r{effects} = effects($rec, $a{recipe}, $a{relaunch});
    if ($sig{V6}[0] eq 'pending-class') {
        $sig{V6} = $r{effects} eq 'none' ? ['pass', 'class none, no recipe'] : ['unmeasured', 'no recipe and not read-only'];
    }

    my $all = !grep { $sig{$_}[0] ne 'pass' } @SIGNALS;
    $r{confidence} = $all ? 'high' : 'low';
    my $failed = grep { $sig{$_}[0] eq 'fail' } @SIGNALS;

    # Status: the D4 table.
    my $live_here = ($a{origin} eq ($a{current}{sid} // '')) && $sig{V3}[0] eq 'pass' && $own->{state} eq 'this';
    if ($own->{state} eq 'elsewhere') { $r{status} = 'RUNNING-ELSEWHERE' }
    elsif ($r{killed}) { $r{status} = 'KILLED' }
    elsif ($own->{state} eq 'cleared' && !defined $r{marker_rc}) { $r{status} = 'RUNNING' }
    elsif ($live_here || ($sig{V5}[0] eq 'fail' && $own->{state} ne 'ended')) { $r{status} = 'RUNNING' }
    elsif ($own->{state} eq 'this' && !defined $r{marker_rc}) { $r{status} = 'ENDED-UNEXPLAINED' }
    elsif ($own->{state} eq 'ended' && $sig{V5}[0] eq 'fail') { $r{status} = 'LEFTOVER' }
    elsif (defined $r{marker_rc} && $r{marker_rc} == 0) { $r{status} = 'DONE-UNREPORTED' }
    elsif (defined $r{marker_rc}) { $r{status} = 'FAILED' }
    elsif ($stopped) { $r{status} = 'STOPPED' }
    elsif ($all) { $r{status} = 'LOST' }
    elsif ($sig{V2}[0] eq 'pass' && !$failed) { $r{status} = 'LOST' }
    else { $r{status} = 'NOT-LOST' }

    # The line a relaunch runs, byte for byte the recorded command (DP-1).
    if (defined $cmd) {
        my $here = skills::util::abs_path($a{cwd} // '') // '';
        if (defined $r{cwd} && (skills::util::abs_path($r{cwd}) // $r{cwd}) ne $here) {
            $r{run_line} = index($r{cwd}, "'") >= 0 ? undef : "cd '$r{cwd}' && $cmd";
        } else {
            $r{run_line} = $cmd;
        }
    }
    return \%r;
}

# signal_line(V, [state, detail]) -> "signal: V1 record pass (detail)"
sub signal_line { my ($v, $s) = @_; return "signal: $v $NAME{$v} $s->[0]" . (defined $s->[1] ? " ($s->[1])" : '') }

sub states { my ($r) = @_; return { map { $_ => $r->{signals}{$_}[0] } @SIGNALS } }

# effects(record, recipe, relaunch settings) -> none | local | outward | unknown
sub effects {
    my ($rec, $recipe, $rl) = @_;
    return 'unknown' unless $rec;
    my $cmd = $rec->{command};
    return 'unknown' if !defined $cmd || (ref $rec->{command_withheld} eq 'ARRAY' && @{ $rec->{command_withheld} });
    my $classes = eval { skills::spec::outward_classes() } || [];
    return 'outward' if grep { $cmd =~ $_->{re} } @$classes;
    return 'outward' if @{ skills::core::secrets_scan($cmd) };
    return 'none' if $rec->{is_read_only} && !$rec->{sandbox_disabled};
    my $outs = $recipe ? expected_outputs($recipe->{text}) : undef;
    return 'local' if $outs && @$outs && grep { $cmd =~ $_ } @{ $rl->{allow} || [] };
    return 'unknown';
}

# Absolute paths named on a recipe's `expected outputs:` line, or undef without one.
sub expected_outputs {
    my ($t) = @_;
    return undef unless defined $t && $t =~ /^\s*expected outputs:[ \t]*(.*?)[ \t]*$/m;
    my $v = $1;
    return [ grep { m{\A/} } map { s/[,;]+\z//r } split /[\s,]+/, $v ];
}

# (rc of the last active end marker in the output's tail or undef, marker expected 0|1,
#  killed 0|1: the last marker is a `means: killed` one)
sub exit_marker {
    my ($path, $cmd) = @_;
    my $w = skills::spec::get('wait') // {};
    my @m = grep { ref $_ eq 'HASH' && $_->{active} && defined $_->{re} } @{ ref $w->{exit_markers} eq 'ARRAY' ? $w->{exit_markers} : [] };
    my $suffix = $w->{end_suffix};
    my $expected = (grep { ($_->{id} // '') eq 'runtime' } @m) ? 1 : 0;
    $expected = 1 if defined $cmd && defined $suffix && $suffix ne '' && substr($cmd, -length $suffix) eq $suffix;
    my $size = -s $path // 0;
    open(my $fh, '<:raw', $path) or return (undef, $expected);
    seek($fh, $size > $TAIL_BYTES ? $size - $TAIL_BYTES : 0, 0);
    read($fh, my $tail, $TAIL_BYTES);
    close $fh;
    my ($rc, $killed) = (undef, 0);
    for my $l (split /\n/, $tail // '') {
        $l =~ s/\r\z//;
        for my $e (@m) {
            my $re = eval { qr/$e->{re}/ } or next;
            next unless $l =~ $re;
            if (($e->{means} // '') eq 'killed') { ($rc, $killed) = (undef, 1) }
            elsif (defined $1) { ($rc, $killed) = ($1, 0) }
        }
    }
    return ($rc, $expected, $killed);
}

sub runnable {
    my ($cmd, $cwd) = @_;
    my @w = grep { $_ ne '' } split /\s+/, $cmd;
    shift @w while @w && $w[0] =~ /\A[A-Za-z_][A-Za-z0-9_]*=/;
    my $first = $w[0] // return 0;
    $first =~ s/\A['"]|['"]\z//g;
    return 1 if $BUILTIN{$first};
    return -x ($first =~ m{\A/} ? $first : "$cwd/$first") ? 1 : 0 if $first =~ m{/};
    return skills::util::which($first) ? 1 : 0;
}

# owner_state(ctx, origin sid, record, current {sid, pid, lstart})
#   -> {state => ended|this|cleared|elsewhere|unverified|unknown, end => epoch|undef}
#   unverified: the owner pid runs but its start time is missing or unreadable (CR-F11)
#   cleared: the origin's process is alive under a later session (/clear); end = that
#   session's start
sub owner_state {
    my ($ctx, $origin, $rec, $cur) = @_;
    my $o = $rec ? $rec->{owner} : undef;
    my $all = skills::ctx::records($ctx);
    my $s8 = skills::ctx::sid8($origin);
    my @live = grep { $_->{state} eq 'live' && ($_->{data}{session_id} // '') eq $origin } @$all;
    my ($pid, $lstart) = ref $o eq 'HASH' ? ($o->{pid}, $o->{lstart}) : ();
    if (!defined $pid) {
        # No record of the job: the origin session's own process records, newest first.
        my ($l) = sort { (skills::util::iso_to_epoch($b->{data}{ts}) // 0) <=> (skills::util::iso_to_epoch($a->{data}{ts}) // 0) } @live;
        return { state => 'unknown' } unless $l;
        ($pid, $lstart) = ($l->{pid}, $l->{data}{pid_lstart});
    }
    my ($lrec) = grep { "$_->{pid}" eq "$pid" && _same_ls($_->{data}{pid_lstart}, $lstart) } @live;
    my $epoch = $lrec ? $lrec->{epoch} : undef;
    if (defined $epoch) {
        my ($end) = grep { $_->{state} eq 'ended' && "$_->{pid}" eq "$pid" && $_->{epoch} eq $epoch && $_->{sid8} eq $s8 } @$all;
        if ($end) {
            my $t = skills::util::iso_to_epoch($end->{data}{ts});
            # /clear ends the session, not the process: its shells survive (DP-24 (c)).
            my $live = ($end->{data}{reason} // '') eq 'clear' ? _cleared($pid, $lstart, $cur, $t) : undef;
            return $live // { state => 'ended', end => $t };
        }
        my $since = skills::util::iso_to_epoch($lrec->{data}{ts}) // 0;
        my @later = sort { $a <=> $b } grep { defined && $_ > $since } map { skills::util::iso_to_epoch($_->{data}{ts}) }
                    grep { $_->{state} eq 'live' && "$_->{pid}" eq "$pid" && $_->{epoch} eq $epoch && ($_->{data}{session_id} // '') ne $origin } @$all;
        # /clear: the same process under a later session. Its shells survive (DP-24 (c)).
        return _cleared($pid, $lstart, $cur, $later[0]) // { state => 'ended', end => $later[0] } if @later;
    }
    # CR-F11: a live pid whose start time cannot be checked is not proof the owner ended.
    my $ps = skills::ctx::pid_state($pid, $lstart);
    return { state => 'ended', end => undef } if $ps eq 'gone';
    return { state => 'unverified', end => undef } if $ps eq 'unverified';
    my $this = defined $cur->{pid} && "$cur->{pid}" eq "$pid" && _same_ls($cur->{lstart}, $lstart);
    return { state => ($this && ($cur->{sid} // '') eq $origin) ? 'this' : ($this ? 'cleared' : 'elsewhere') };
}

# The origin's process after a /clear: undef when it is gone; `cleared` when it is this
# process, else `elsewhere` (another live process runs the job, if it still runs).
sub _cleared {
    my ($pid, $lstart, $cur, $t) = @_;
    my $ps = skills::ctx::pid_state($pid, $lstart);
    return undef if $ps eq 'gone';
    return { state => 'unverified', end => $t } if $ps eq 'unverified';
    my $this = defined $cur->{pid} && "$cur->{pid}" eq "$pid" && _same_ls($cur->{lstart}, $lstart);
    return { state => ($this ? 'cleared' : 'elsewhere'), end => $t };
}

sub _same_ls { my ($x, $y) = @_; return 0 unless defined $x && defined $y; s/\s+/ /g, s/\A | \z//g for $x, $y; return $x eq $y }

# The task in the origin session's newest sidecar slot: the task hash, '' when the slot
# does not list it, undef without a slot. $strict 0: undef also when not listed.
sub _sidecar_task {
    my ($odir, $task, $strict) = @_;
    my ($slot) = skills::core::sidecar_newest($odir);
    return undef unless $slot;
    for my $key (qw(tasks background_tasks)) {
        for my $t (@{ ref $slot->{$key} eq 'ARRAY' ? $slot->{$key} : [] }) {
            return $t if ref $t eq 'HASH' && ($t->{id} // $t->{task_id} // '') eq $task;
        }
    }
    return $strict ? '' : undef;
}

# The origin session's transcript: <config dir>/projects/<slug of its cwd>/<sid>.jsonl for
# the cwd of its process records and of the job, then a summary copy's transcript_path.
sub transcript_of {
    my ($ctx, $origin, $rec) = @_;
    my $cfg = skills::util::env('CLAUDE_CONFIG_DIR') // ((skills::util::env('HOME') // '') . '/.claude');
    my %cwd;
    $cwd{ $rec->{cwd} } = 1 if $rec && defined $rec->{cwd};
    for my $r (@{ skills::ctx::records($ctx) }) {
        next unless ($r->{data}{session_id} // '') eq $origin;
        $cwd{ $r->{data}{cwd} } = 1 if defined $r->{data}{cwd};
    }
    for my $c (sort keys %cwd) {
        (my $slug = $c) =~ s/[^A-Za-z0-9]/-/g;
        my $p = "$cfg/projects/$slug/$origin.jsonl";
        return $p if -f $p;
    }
    return undef;
}

# 1 when the transcript holds a Bash tool_use whose command has this sha and a tool result
# for it naming this backgroundTaskId; 0 when not; 'partial' when not found in a
# transcript longer than the scan window (only its last $TRANSCRIPT_MAX bytes are read;
# STORE_TEST_TRANSCRIPT_MAX sets the window in test mode); undef when unreadable.
# Content is read in memory and never printed.
sub transcript_has {
    my ($path, $sha, $task) = @_;
    return 0 unless defined $sha && defined $task;
    my $size = -s $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $max = $TRANSCRIPT_MAX;
    $max = 0 + $ENV{STORE_TEST_TRANSCRIPT_MAX}
        if skills::util::test_mode() && ($ENV{STORE_TEST_TRANSCRIPT_MAX} // '') =~ /\A[1-9][0-9]{0,9}\z/;
    my $partial = defined $size && $size > $max;
    seek($fh, $size - $max, 0) if $partial;
    my (%use, $hit);
    while (my $l = <$fh>) {
        if (index($l, '"tool_use"') >= 0 && index($l, '"Bash"') >= 0) {
            my $j = eval { skills::util::json_decode($l) } or next;
            for my $c (@{ _content($j) }) {
                next unless ref $c eq 'HASH' && ($c->{type} // '') eq 'tool_use' && ($c->{name} // '') eq 'Bash';
                my $cmd = ref $c->{input} eq 'HASH' ? $c->{input}{command} : undef;
                $use{ $c->{id} } = 1 if defined $cmd && defined $c->{id} && skills::util::sha256_hex($cmd) eq $sha;
            }
        }
        if (%use && index($l, $task) >= 0 && index($l, 'backgroundTaskId') >= 0) {
            my $j = eval { skills::util::json_decode($l) } or next;
            my $tr = ref $j->{toolUseResult} eq 'HASH' ? $j->{toolUseResult} : {};
            next unless ($tr->{backgroundTaskId} // '') eq $task;
            for my $c (@{ _content($j) }) {
                if (ref $c eq 'HASH' && defined $c->{tool_use_id} && $use{ $c->{tool_use_id} }) { $hit = 1; last }
            }
        }
        last if $hit;
    }
    close $fh;
    return $hit ? 1 : $partial ? 'partial' : 0;
}

sub _content {
    my ($j) = @_;
    my $m = ref $j->{message} eq 'HASH' ? $j->{message} : {};
    return ref $m->{content} eq 'ARRAY' ? $m->{content} : [];
}

1;

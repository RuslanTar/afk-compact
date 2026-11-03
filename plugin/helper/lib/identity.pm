package identity;
# lib/identity.pm: Claude Code process id and start time (MOD-SPEC §2.1, S-17).
# Owner: WP-core. Ancestor walk to the first process whose command is the Claude
# Code binary (or whose pid CLAUDE_PID names); a nearer process whose command hides the
# binary but whose executable is it wins (a background session's worker). Start time:
# Linux /proc/<pid>/stat field 22 + btime (R-4); else `ps -o lstart=`. Every start-time
# read of one pid in the helper goes through _read_start; start_epochs reads many at once (the
# same /proc fields, else one `ps -axo` listing).
# Test mode: STORE_TEST_CLAUDE_PID=<pid>:<lstart> replaces the walk.
use strict;
use warnings;
use utf8;
use POSIX ();

my %START;

sub _is_claude {
    my ($comm) = @_;
    return 0 unless defined $comm;
    $comm =~ s/\s+$//;
    my $b = util::basename($comm);
    return 1 if $b eq 'claude' || $b eq 'claude.exe';
    return 1 if $comm =~ m{/claude/versions/[^/]+$};
    return 0;
}

# _proc_stat(pid) -> (comm, ppid, starttime ticks) from /proc/<pid>/stat (proc(5)): 1 pid,
# 2 (comm), 3 state, 4 ppid, 5-21 pgrp .. itrealvalue (17 fields), 22 starttime, 23 vsize.
# comm is in parentheses and may hold spaces, parentheses and newlines (the greedy match ends
# at the last `)`); the fields after it hold none. Before this fix the pattern skipped 18
# fields and read field 23 (the process size in bytes), so a start time moved with memory.
sub _proc_stat {
    my ($pid) = @_;
    my $raw = util::read_file("/proc/$pid/stat") // return;
    return unless $raw =~ /^\d+ \((.*)\) (\S) (\d+)(?: \S+){17} (\d+)/s;
    return ($1, $3, $4);
}

my $BTIME;
sub _btime {
    return $BTIME if defined $BTIME;
    my $raw = util::read_file('/proc/stat') // '';
    ($BTIME) = $raw =~ /^btime (\d+)/m;
    $BTIME //= 0;
    return $BTIME;
}

# _read_start(pid, ps) -> (epoch, lstart string), both undef when unreadable; never cached.
# Linux with a readable /proc/<pid>/stat: field 22 + btime (R-4), so no `ps` is needed (a
# slim image has no procps); else `ps -o lstart=` (ps: a path, default the first on PATH).
sub _read_start {
    my ($pid, $ps) = @_;
    return (undef, undef) unless defined $pid && $pid =~ /^\d+$/;
    if ($^O eq 'linux' && -r "/proc/$pid/stat") {
        my (undef, undef, $ticks) = _proc_stat($pid);
        return (undef, undef) unless defined $ticks;
        my $hz = eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
        my $epoch = _btime() + int($ticks / $hz);
        my $s = POSIX::strftime('%a %b %e %H:%M:%S %Y', localtime $epoch);
        $s =~ s/  / /g;
        return ($epoch, $s);
    }
    $ps //= util::which('ps') // return (undef, undef);
    my $r = util::run([$ps, '-o', 'lstart=', '-p', $pid], timeout_ms => 2000, env => { LC_ALL => 'C', LANG => 'C' });
    return (undef, undef) unless $r->{exit} == 0;
    (my $s = $r->{out}) =~ s/^\s+|\s+$//g;
    $s =~ s/\s+/ /g;
    return (undef, undef) if $s eq '';
    return (lstart_epoch($s), $s);
}

# start_time(pid) -> string in `ps -o lstart=` form ("Tue Oct 21 14:05:12 2026"), or undef.
# Cached per pid for the life of this process.
sub start_time {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/;
    return $START{$pid} if exists $START{$pid};
    my (undef, $s) = _read_start($pid);
    $START{$pid} = $s;
    return $s;
}

# start_epoch(pid, ps => path) -> seconds since epoch of the process start, or undef. Not
# cached, so a reused pid shows its new start (the wait helper polls with it).
sub start_epoch {
    my ($pid, %o) = @_;
    my ($e) = _read_start($pid, $o{ps});
    return $e;
}

# start_epochs([pid ...]) -> {pid => epoch | 0 | undef}: when each pid's process started, in the
# seconds that a record's key holds (lstart_epoch of its lstart string); 0 when the pid does not
# run; undef when it runs (or may) but its start cannot be read. Linux: /proc/<pid>/stat where
# readable (field 22 + btime, as _read_start; no /proc/<pid>: 0). Elsewhere, and for a Linux pid
# whose stat is not readable: kill 0, then one `ps -axo pid=,lstart=` listing for all the pids
# that run (read once per process: a daily prune's hundreds of pids cost one ps, not hundreds); a
# pid it lacks, or no listing (no ps, one without -o): undef. Test mode: STORE_TEST_PROC_STARTS
# names a file of `<pid> <epoch>` lines (`<pid> ?`: start unknown) that replaces all of it: an
# unlisted pid does not run. The load and record prunes use it (lib/plugver.pm, lib/sessions.pm).
my $PS_STARTS;
sub start_epochs {
    my ($pids) = @_;
    my %out;
    my @want = grep { defined && !ref && /\A[1-9][0-9]{0,9}\z/ } @{ $pids || [] };
    if (util::test_mode() && defined $ENV{STORE_TEST_PROC_STARTS} && $ENV{STORE_TEST_PROC_STARTS} ne '') {
        my %t;
        for my $l (split /\n/, util::read_file($ENV{STORE_TEST_PROC_STARTS}) // '') {
            $t{$1} = ($2 eq '?' ? undef : 0 + $2) if $l =~ /\A\s*(\d+)\s+(\d+|\?)\s*\z/;
        }
        $out{$_} = exists $t{$_} ? $t{$_} : 0 for @want;
        return \%out;
    }
    my $proc = $^O eq 'linux' && -r '/proc/self/stat';
    my @ps;
    for my $p (@want) {
        next if exists $out{$p};
        if ($proc && -r "/proc/$p/stat") {
            my (undef, undef, $ticks) = _proc_stat($p);
            if (defined $ticks) {
                my $hz = eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
                my $s = POSIX::strftime('%a %b %e %H:%M:%S %Y', localtime(_btime() + int($ticks / $hz)));
                $s =~ s/  / /g;
                $out{$p} = lstart_epoch($s);
                next;
            }
        } elsif ($proc && !-e "/proc/$p") {
            $out{$p} = 0;
            next;
        }
        if (!(kill(0, $p) || $!{EPERM})) { $out{$p} = 0; next }
        $out{$p} = undef;
        push @ps, $p;
    }
    if (@ps) {
        my $t = _ps_starts();
        $out{$_} = $t->{$_} for grep { defined $t->{$_} } @ps;
    }
    return \%out;
}

sub _ps_starts {
    return $PS_STARTS if $PS_STARTS;
    my %t;
    my $ps = util::which('ps');
    my $r = defined $ps ? util::run([$ps, '-axo', 'pid=,lstart='], timeout_ms => 5000, env => { LC_ALL => 'C', LANG => 'C' }) : undef;
    if ($r && $r->{exit} == 0) {
        for my $l (split /\n/, $r->{out} // '') {
            next unless $l =~ /\A\s*(\d+)\s+(\S.*?)\s*\z/;
            my ($pid, $s) = ($1, $2);
            $s =~ s/\s+/ /g;
            my $e = lstart_epoch($s);
            $t{$pid} = $e if defined $e;
        }
    }
    return $PS_STARTS = \%t;
}

# key_live(key, starts) -> 1 when a record key `<pid>-<start epoch>` may name a process that still
# runs, by start_epochs' answer: its pid runs with that start (2 s apart at most: a Linux boot time
# read twice may differ by a second), or with a start that cannot be read, or the key holds no
# start (0: unreadable when the record was written). 0 when the pid does not run or runs with
# another start (the pid was reused).
sub key_live {
    my ($key, $starts) = @_;
    return 0 unless defined $key && $key =~ /\A(\d+)-(\d+)\z/ && $1 > 1;
    my ($pid, $e) = ($1, $2);
    return 1 unless ref $starts eq 'HASH' && exists $starts->{$pid};
    my $now = $starts->{$pid};
    return 1 unless defined $now;
    return 0 if $now == 0;
    return 1 if $e == 0;
    return abs($now - $e) <= 2 ? 1 : 0;
}

# Seconds since epoch for an lstart string (digits pass through).
sub lstart_epoch {
    my ($l) = @_;
    return undef unless defined $l;
    return 0 + $l if $l =~ /^\d+$/;
    my %mon = (Jan => 1, Feb => 2, Mar => 3, Apr => 4, May => 5, Jun => 6, Jul => 7, Aug => 8, Sep => 9, Oct => 10, Nov => 11, Dec => 12);
    return undef unless $l =~ /^\w{3} (\w{3}) +(\d+) (\d\d):(\d\d):(\d\d) (\d{4})$/;
    return POSIX::mktime($5, $4, $3, $2, $mon{$1} - 1, $6 - 1900, 0, 0, -1);
}

# Test mode: STORE_TEST_PROC=<file> holds a fake process table, one `pid ppid command` line per
# process; _parent_and_comm reads it instead of /proc or ps (the restart launcher's ancestor
# check, SESSION-RESTART G3, helper cases AT-RS-21 and AT-RS-29).
sub _fake_proc {
    my ($pid) = @_;
    my $raw = util::read_file($ENV{STORE_TEST_PROC}) // return;
    for my $l (split /\n/, $raw) {
        return ($2, $3) if $l =~ /^\s*(\d+)\s+(\d+)\s+(.*?)\s*$/ && $1 == $pid;
    }
    return;
}

sub _parent_and_comm {
    my ($pid) = @_;
    return _fake_proc($pid) if util::test_mode() && defined $ENV{STORE_TEST_PROC} && $ENV{STORE_TEST_PROC} ne '';
    if ($^O eq 'linux' && -r "/proc/$pid/stat") {
        my ($comm, $ppid) = _proc_stat($pid);
        my $exe = readlink("/proc/$pid/exe");
        return ($ppid, defined $exe ? $exe : $comm);
    }
    my $ps = util::which('ps') // return;
    my $r = util::run([$ps, '-o', 'ppid=,comm=', '-p', $pid], timeout_ms => 2000, env => { LC_ALL => 'C' });
    return unless $r->{exit} == 0 && $r->{out} =~ /^\s*(\d+)\s+(.*?)\s*$/s;
    return ($1, $2);
}

# _exe(pid) -> the process's executable path, or undef. Linux: /proc/<pid>/exe; elsewhere
# the first `txt` file lsof lists for it (the executable on macOS, also when argv[0] was set
# to another name).
sub _exe {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/;
    return scalar readlink("/proc/$pid/exe") if $^O eq 'linux';
    my $lsof = -x '/usr/sbin/lsof' ? '/usr/sbin/lsof' : (util::which('lsof') // return undef);
    my $r = util::run([$lsof, '-a', '-p', $pid, '-d', 'txt', '-Fn'], timeout_ms => 1000, env => { LC_ALL => 'C' });
    return undef unless $r->{exit} == 0;
    for my $l (split /\n/, $r->{out} // '') { return substr($l, 1) if $l =~ m{^n/} }
    return undef;
}

# Command names that are never the Claude Code binary: the walk reads no executable for them.
my %NOT_CLAUDE = map { $_ => 1 } qw(sh bash zsh dash ash ksh mksh fish env perl sudo timeout gtimeout nice nohup);
sub _never_claude {
    my ($comm) = @_;
    return 1 unless defined $comm && $comm ne '';
    (my $b = $comm) =~ s/\s.*//s;
    $b = util::basename($b);
    $b =~ s/^-//;
    return $NOT_CLAUDE{$b} ? 1 : 0;
}

# At most this many executables are read per walk (each an lsof call on macOS, ~70 ms).
our $EXE_PROBES = 3;

# _by_exe([[pid, comm]...]) -> the first pid whose executable is the Claude Code binary, or undef.
# A hop whose executable cannot be read (lsof failed or timed out) ends the scan: a process past
# it (a background worker's pty host, which runs the binary too) is never taken in its place.
sub _by_exe {
    my ($hops) = @_;
    my $n = 0;
    for my $h (@$hops) {
        next if _never_claude($h->[1]);
        last if ++$n > $EXE_PROBES;
        my $x = _exe($h->[0]);
        return undef unless defined $x;
        return $h->[0] if _is_claude($x);
    }
    return undef;
}

# _walk(pid) -> (claude pid, 1) or (undef, 0): from pid (the helper's parent) up at most 12
# processes. The anchor is the first one whose command is the binary, or whose pid CLAUDE_PID
# names (Claude Code sets it to its own pid for hooks). Probe 2026-10-27: a background session's
# worker runs under a name that hides the binary, so the walk passed it and took its supervisor
# (`claude daemon`), whose pid every background session then shared. So the hops below the
# anchor are checked by their executable first, nearest first; a foreground session's helper,
# whose parent is the anchor, reads none, and with no anchor (a helper run from a terminal) none
# is read either.
sub _walk {
    my ($pid) = @_;
    my $env = (defined $ENV{CLAUDE_PID} && $ENV{CLAUDE_PID} =~ /^[1-9][0-9]*$/) ? 0 + $ENV{CLAUDE_PID} : 0;
    my @below;
    for (1 .. 12) {
        last if !$pid || $pid <= 1;
        my ($ppid, $comm) = _parent_and_comm($pid);
        last unless defined $ppid;
        if ($pid == $env || _is_claude($comm)) {
            my $w = _by_exe(\@below);
            return (defined $w ? 0 + $w : 0 + $pid, 1);
        }
        push @below, [$pid, $comm];
        $pid = $ppid;
    }
    return (undef, 0);
}

our $CACHED;
# claude_pid() -> {pid, lstart, found}
sub claude_pid {
    return $CACHED if $CACHED;
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/) {
        # STORE_TEST_CLAUDE_FOUND=0: the walk's verdict when it did not find Claude Code (the pid is then a fallback)
        $CACHED = { pid => 0 + $1, lstart => $2, found => (($ENV{STORE_TEST_CLAUDE_FOUND} // '') eq '0' ? 0 : 1) };
        $START{$1} = $2;
        return $CACHED;
    }
    my $first = getppid();
    my ($pid, $found) = _walk($first);
    $pid //= $first;
    $CACHED = { pid => 0 + $pid, lstart => start_time($pid), found => $found };
    return $CACHED;
}

# alive(pid, lstart) -> 1 when the pid runs and its start time matches.
# A Linux record written before the R-4 fix holds btime + vsize/HZ in place of the start time.
# It is judged like any other: its pid runs with another start time, so it counts as ended
# (S-17). The old code reached the same verdict once the process's size had changed since the
# record was written (its own reading moved with memory); only a record whose process kept its
# size gets another verdict now. Such records matter only while processes started before the
# upgrade still run.
sub alive {
    my ($pid, $lstart) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return 0 unless kill(0, $pid) || $!{EPERM};
    return 1 unless defined $lstart && $lstart ne '';
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/ && $1 == $pid) {
        return $2 eq $lstart ? 1 : 0;
    }
    my $now = start_time($pid);
    return 0 unless defined $now;
    return $now eq $lstart ? 1 : 0;
}

# launcher_above(pid, launcher, max) -> 'ok', 'nested' or 'not-ancestor' (SESSION-RESTART G3):
# the walk from pid's parent up at most max processes reaches the launcher pid with no
# process whose command is the Claude Code binary between them. A wrapper (teamclaude, node, a
# shell) between them is fine; another claude there means pid is a nested session.
sub launcher_above {
    my ($pid, $launcher, $max) = @_;
    return 'not-ancestor' unless defined $pid && $pid =~ /^\d+$/ && defined $launcher && $launcher =~ /^\d+$/;
    my ($cur) = _parent_and_comm($pid);
    for (1 .. ($max // 8)) {
        last unless defined $cur;
        return 'ok' if $cur == $launcher;
        last if $cur <= 1;
        my ($ppid, $comm) = _parent_and_comm($cur);
        return 'nested' if _is_claude($comm);
        $cur = $ppid;
    }
    return 'not-ancestor';
}

sub host { my @u = POSIX::uname(); return $u[1] // 'unknown' }

1;

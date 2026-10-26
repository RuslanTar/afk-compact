package identity;
# lib/identity.pm: Claude Code process id and start time (MOD-SPEC §2.1, S-17).
# Owner: WP-core. Ancestor walk to the first process whose command is the Claude
# Code binary. Start time: Linux /proc/<pid>/stat field 22 + btime (R-4); else
# `ps -o lstart=`. Every start-time read in the helper goes through _read_start.
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

# Seconds since epoch for an lstart string (digits pass through).
sub lstart_epoch {
    my ($l) = @_;
    return undef unless defined $l;
    return 0 + $l if $l =~ /^\d+$/;
    my %mon = (Jan => 1, Feb => 2, Mar => 3, Apr => 4, May => 5, Jun => 6, Jul => 7, Aug => 8, Sep => 9, Oct => 10, Nov => 11, Dec => 12);
    return undef unless $l =~ /^\w{3} (\w{3}) +(\d+) (\d\d):(\d\d):(\d\d) (\d{4})$/;
    return POSIX::mktime($5, $4, $3, $2, $mon{$1} - 1, $6 - 1900, 0, 0, -1);
}

sub _parent_and_comm {
    my ($pid) = @_;
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

my $CACHED;
# claude_pid() -> {pid, lstart, found}
sub claude_pid {
    return $CACHED if $CACHED;
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/) {
        $CACHED = { pid => 0 + $1, lstart => $2, found => 1 };
        $START{$1} = $2;
        return $CACHED;
    }
    my $pid = getppid();
    my $first = $pid;
    for (1 .. 12) {
        last if !$pid || $pid <= 1;
        my ($ppid, $comm) = _parent_and_comm($pid);
        last unless defined $ppid;
        if (_is_claude($comm)) {
            $CACHED = { pid => 0 + $pid, lstart => start_time($pid), found => 1 };
            return $CACHED;
        }
        $pid = $ppid;
    }
    $CACHED = { pid => 0 + $first, lstart => start_time($first), found => 0 };
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

sub host { my @u = POSIX::uname(); return $u[1] // 'unknown' }

1;

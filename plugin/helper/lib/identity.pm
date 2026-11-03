package identity;
# lib/identity.pm: Claude Code process id and start time (MOD-SPEC §2.1, S-17).
# Owner: WP-core. Ancestor walk to the first process whose command is the Claude
# Code binary (or whose pid CLAUDE_PID names); a nearer process whose command hides the
# binary but whose executable is it wins (a background session's worker). Start time:
# Linux /proc/<pid>/stat field 22 + btime (R-4); else `ps -o lstart=`. Every start-time
# read in the helper goes through _read_start.
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
# is read either. A hop that CLAUDE_PID names is the anchor before its own parent and command are
# read (0.1.4 T-14): a hook's helper whose parent is Claude Code itself makes no `ps` call here.
sub _walk {
    my ($pid) = @_;
    my $env = (defined $ENV{CLAUDE_PID} && $ENV{CLAUDE_PID} =~ /^[1-9][0-9]*$/) ? 0 + $ENV{CLAUDE_PID} : 0;
    my @below;
    for (1 .. 12) {
        last if !$pid || $pid <= 1;
        if ($pid == $env) {
            my $w = _by_exe(\@below);
            return (defined $w ? 0 + $w : 0 + $pid, 1);
        }
        my ($ppid, $comm) = _parent_and_comm($pid);
        last unless defined $ppid;
        if (_is_claude($comm)) {
            my $w = _by_exe(\@below);
            return (defined $w ? 0 + $w : 0 + $pid, 1);
        }
        push @below, [$pid, $comm];
        $pid = $ppid;
    }
    return (undef, 0);
}

our $CACHED;
# $OWN_START = 1 (main.pl sets it for hook SessionStart, the writer of classic-alive.json): the
# start time is always read, never taken from that record. A new Claude Code process may hold the
# pid of the session's earlier one (a container with fixed pids, `claude --resume`), and a record
# trusted there would keep the earlier start time for good.
our $OWN_START = 0;
# claude_pid() -> {pid, lstart, found}. The start time comes from this session's
# classic-alive.json (SessionStart writes it for the process it ran in: {pid, pid_lstart}) when
# that record names the same pid, else from start_time (one `ps` call off Linux; 0.1.4 T-14).
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
    my $d = !$OWN_START && defined &rc::sid_dir ? eval { rc::sid_dir() } : undef;
    my $raw = defined $d ? util::read_file("$d/classic-alive.json", 4096) : undef;
    my $rec = defined $raw ? eval { jsonc::decode($raw) } : undef;
    my $ls = ref $rec eq 'HASH' && defined $rec->{pid} && !ref $rec->{pid} && $rec->{pid} =~ /\A[1-9][0-9]*\z/ && $rec->{pid} == $pid
             && defined $rec->{pid_lstart} && !ref $rec->{pid_lstart} && $rec->{pid_lstart} =~ /\S/ ? $rec->{pid_lstart} : undef;
    $CACHED = { pid => 0 + $pid, lstart => $ls // start_time($pid), found => $found };
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

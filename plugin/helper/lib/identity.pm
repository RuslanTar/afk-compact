package identity;
# lib/identity.pm: Claude Code process id and start time.
# Ancestor walk to the first process whose command is the Claude
# Code binary (or whose pid CLAUDE_PID names); a nearer process whose command hides the
# binary but whose executable is it wins (a background session's worker). Start time:
# Linux, MSYS and Cygwin /proc/<pid>/stat field 22 + btime; else `ps -o lstart=`.
# Every start-time read of one pid in the helper goes through _read_start; start_epochs reads
# many at once (the same /proc fields on the same platforms, else one `ps -axo` listing).
# Test mode: STORE_TEST_CLAUDE_PID=<pid>:<lstart> replaces the walk; STORE_TEST_PPID=<pid>
# stands in for getppid() where the walk starts; STORE_TEST_PROC_ROOT=<dir> stands in for /proc
# in the start-time read (with util::os's STORE_TEST_OS); STORE_TEST_WINPIDS and STORE_TEST_PS_W
# stand in for the Windows pid map and the `ps -W` listing (win_probe).
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
    my $raw = util::read_file(_proc() . "/$pid/stat") // return;
    return unless $raw =~ /^\d+ \((.*)\) (\S) (\d+)(?: \S+){17} (\d+)/s;
    return ($1, $3, $4);
}

my $BTIME;
sub _btime {
    return $BTIME if defined $BTIME;
    my $raw = util::read_file(_proc() . '/stat') // '';
    ($BTIME) = $raw =~ /^btime (\d+)/m;
    $BTIME //= 0;
    return $BTIME;
}

# _proc() -> /proc, or STORE_TEST_PROC_ROOT in test mode.
sub _proc {
    return $ENV{STORE_TEST_PROC_ROOT} if util::test_mode() && defined $ENV{STORE_TEST_PROC_ROOT} && $ENV{STORE_TEST_PROC_ROOT} =~ m{\A/};
    return '/proc';
}

# cyg() -> 1 under MSYS or Cygwin perl (util::os, so STORE_TEST_OS in test mode).
sub cyg { my $os = util::os(); return $os eq 'msys' || $os eq 'cygwin' ? 1 : 0 }

# Windows pids under MSYS and Cygwin perl. Claude Code is a native Windows program: the CLAUDE_PID
# it sets, which every record holds, is its Windows pid, which this perl's kill 0 and /proc do not
# know. A claude started from Git Bash has an MSYS pid too (winpid 12044 was MSYS pid 772 on the
# PC); one started from PowerShell, cmd or Windows Terminal has none.
# win_probe(pid) -> ('run', pid to read) | ('unknown') | ('gone'), under MSYS and Cygwin only:
#   - /proc/<pid> exists: an MSYS pid, as on Linux: run when kill 0 reaches it, else gone;
#   - else the pid read as a Windows pid and mapped to its MSYS pid (_winpid_to_pid): run, with
#     that pid's kill 0 and /proc start time, when kill 0 reaches it, else gone;
#   - else one `ps -W` listing (_ps_w): a pid in its WINPID column is alive-unknown (it runs, its
#     start time cannot be read), one not listed is gone, and with no listing it is unknown.
# Only a pid that a record took from CLAUDE_PID may be a Windows pid: a record of a helper's own
# $$ (a lock holder) holds an MSYS pid and is judged by alive_own, never through this.
# liveness(pid) -> 'run' | 'unknown' | 'gone': kill 0 (EPERM counts as running) anywhere else.
sub liveness {
    my ($pid) = @_;
    return 'gone' unless defined $pid && !ref $pid && $pid =~ /\A\d+\z/ && $pid > 0;
    if (cyg()) { my ($st) = win_probe($pid); return $st }
    return (kill(0, $pid) || $!{EPERM}) ? 'run' : 'gone';
}

sub win_probe {
    my ($pid) = @_;
    return ('gone') unless defined $pid && !ref $pid && $pid =~ /\A[1-9][0-9]{0,9}\z/;
    if (-e (_proc() . "/$pid")) { return (kill(0, $pid) || $!{EPERM}) ? ('run', 0 + $pid) : ('gone') }
    my $m = _win_msys($pid);
    if (defined $m) { return (kill(0, $m) || $!{EPERM}) ? ('run', $m) : ('gone') }
    my $l = _ps_w() // return ('unknown');
    return $l->{$pid} ? ('unknown') : ('gone');
}

# _win_msys(pid) -> the MSYS pid that pid, read as a Windows pid, maps to (_winpid_to_pid) when
# that is another pid with a /proc entry, else undef. The map only: never the `ps -W` listing.
sub _win_msys {
    my ($pid) = @_;
    my $m = _winpid_to_pid($pid);
    return defined $m && $m != $pid && -e (_proc() . "/$m") ? $m : undef;
}

# win_alt_start(pid) -> under MSYS and Cygwin, the start time (lstart form) of the MSYS process
# that pid maps to when read as a Windows pid (_win_msys), else undef. A pid with a /proc entry is
# judged as that MSYS process first (win_probe); a recorded start time that differs from its
# start is checked against this one before the record is taken as ended, since the same number
# may be a live claude's Windows pid (Git Bash shape: its MSYS stub holds the recorded start).
sub win_alt_start {
    my ($pid) = @_;
    return undef unless cyg() && defined $pid && !ref $pid && $pid =~ /\A[1-9][0-9]{0,9}\z/;
    my $m = _win_msys($pid) // return undef;
    my (undef, $s) = _read_start($m);
    return $s;
}

# Cygwin gives a Windows process with no Cygwin pid the pseudo-pid winpid + this (ps -W showed
# 4204488 for winpid 10184): never an MSYS pid with a /proc entry.
our $CYG_MAX_PID = 4194304;
our $WIN_CACHE_MS = 2000;
# A `ps -W` that takes longer gives no listing (unknown): it can run inside a hook's orphans pass.
our $PSW_TIMEOUT_MS = 1000;
my ($WINMAP, $WINMAP_AT, $PSW, $PSW_AT);

# _stand_in() -> 1 in test mode with a stand-in /proc (STORE_TEST_PROC_ROOT): that process world is
# the case's, so the host's real winpid map and `ps -W` are never read for it, on any host.
sub _stand_in { return util::test_mode() && _proc() ne '/proc' ? 1 : 0 }

# _winpid_to_pid(winpid) -> its MSYS pid, or undef: Cygwin::winpid_to_pid when perl has it, else
# one scan of /proc/*/winpid (kept $WIN_CACHE_MS). Test mode: STORE_TEST_WINPIDS=<file> of
# `<winpid> <pid>` lines replaces both (an unlisted winpid maps to nothing); STORE_TEST_NO_CYGWIN=1
# or a stand-in /proc (_stand_in) hides the real sub, as for util's path subs, so the scan reads
# STORE_TEST_PROC_ROOT.
sub _winpid_to_pid {
    my ($w) = @_;
    my $m;
    if (util::test_mode() && defined $ENV{STORE_TEST_WINPIDS} && $ENV{STORE_TEST_WINPIDS} ne '') {
        for my $l (split /\n/, util::read_file($ENV{STORE_TEST_WINPIDS}) // '') {
            if ($l =~ /\A\s*(\d+)\s+(\d+)\s*\z/ && $1 == $w) { $m = 0 + $2; last }
        }
    } elsif (do { no strict 'refs'; defined &{'Cygwin::winpid_to_pid'} } && !(util::test_mode() && ($ENV{STORE_TEST_NO_CYGWIN} // '') eq '1') && !_stand_in()) {
        no strict 'refs';
        $m = eval { &{'Cygwin::winpid_to_pid'}(0 + $w) };
    } else {
        my $now = util::clock_ms();
        if (!$WINMAP || $now - $WINMAP_AT > $WIN_CACHE_MS) {
            my %t;
            for my $p (grep { /\A[1-9][0-9]*\z/ } util::list_dir(_proc())) {
                my $raw = util::read_file(_proc() . "/$p/winpid", 64) // next;
                $t{$1} //= 0 + $p if $raw =~ /\A\s*(\d+)\s*\z/;
            }
            ($WINMAP, $WINMAP_AT) = (\%t, $now);
        }
        $m = $WINMAP->{0 + $w};
    }
    return undef unless defined $m && !ref $m && $m =~ /\A[1-9][0-9]*\z/ && $m < $CYG_MAX_PID;
    return 0 + $m;
}

# _ps_w() -> {winpid => 1} of every Windows process `ps -W` lists (its WINPID column), kept
# $WIN_CACHE_MS; undef when there is no listing (no ps, a failure or a timeout after
# $PSW_TIMEOUT_MS, nothing parsed): an unknown answer, never a gone one. Read only under a real
# MSYS or Cygwin perl, and never for a stand-in /proc (_stand_in). Test mode:
# STORE_TEST_PS_W=<file> holds the listing, read as a real one: its header line alone means no Windows
# process runs; a missing file, or text with neither that header nor a row that parses, means no listing.
sub _ps_w {
    my $now = util::clock_ms();
    return $PSW if $PSW_AT && $now - $PSW_AT <= $WIN_CACHE_MS;
    my $raw;
    if (util::test_mode() && defined $ENV{STORE_TEST_PS_W} && $ENV{STORE_TEST_PS_W} ne '') {
        $raw = util::read_file($ENV{STORE_TEST_PS_W});
    } elsif (($^O eq 'msys' || $^O eq 'cygwin') && !_stand_in()) {
        my $ps = util::which('ps');
        my $r = defined $ps ? util::run([$ps, '-W'], timeout_ms => $PSW_TIMEOUT_MS, env => { LC_ALL => 'C', LANG => 'C' }) : undef;
        $raw = $r && $r->{exit} == 0 ? $r->{out} : undef;
    }
    my $t;
    if (defined $raw) {
        my %w;
        # [status letter] PID PPID PGID WINPID TTY UID STIME COMMAND
        for my $l (split /\n/, $raw) { $w{ 0 + $1 } = 1 if $l =~ /\A\s*(?:[A-Za-z]\s+)?\d+\s+\d+\s+\d+\s+(\d+)\s/ }
        $t = (%w || $raw =~ /^\s*PID\s+PPID\s+PGID\s+WINPID\s/m) ? \%w : undef;
    }
    ($PSW, $PSW_AT) = ($t, $now);
    return $t;
}

# _read_start(pid, ps) -> (epoch, lstart string), both undef when unreadable; never cached.
# Linux with a readable /proc/<pid>/stat: field 22 + btime, so no `ps` is needed (a
# slim image has no procps); else `ps -o lstart=` (ps: a path, default the first on PATH).
# MSYS and Cygwin (Git Bash's perl): /proc/<pid>/stat only, as on Linux; their ps has no -o
# (`ps: unknown option -- o`), so without it the start stays unknown. A Windows pid there (no
# /proc/<pid>) reads its MSYS pid's /proc start (_win_msys: the map only, no `ps -W`, which could
# not tell a start time); with none it stays unknown.
sub _read_start {
    my ($pid, $ps) = @_;
    return (undef, undef) unless defined $pid && $pid =~ /^\d+$/;
    my $os = util::os();
    my $cyg = $os eq 'msys' || $os eq 'cygwin';
    if ($cyg && $pid > 0 && !-e (_proc() . "/$pid")) {
        $pid = _win_msys($pid) // return (undef, undef);
    }
    if (($os eq 'linux' || $cyg) && -r (_proc() . "/$pid/stat")) {
        my (undef, undef, $ticks) = _proc_stat($pid);
        return (undef, undef) unless defined $ticks;
        my $hz = eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
        my $epoch = _btime() + int($ticks / $hz);
        my $s = POSIX::strftime('%a %b %e %H:%M:%S %Y', localtime $epoch);
        $s =~ s/  / /g;
        return ($epoch, $s);
    }
    return (undef, undef) if $cyg;
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

# start_time_own(pid) -> start_time of a helper process's own pid ($$, a lock holder): under MSYS
# and Cygwin by MSYS rules only (its own /proc entry, never the winpid map; alive_own).
sub start_time_own {
    my ($pid) = @_;
    return start_time($pid) unless cyg();
    return undef unless defined $pid && $pid =~ /^\d+$/ && -e (_proc() . "/$pid");
    return start_time($pid);
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
# run; undef when it runs (or may) but its start cannot be read. Linux, MSYS and Cygwin:
# /proc/<pid>/stat where readable (field 22 + btime, as _read_start; no /proc/<pid>: 0). Elsewhere,
# and for a Linux pid whose stat is not readable: kill 0, then one `ps -axo pid=,lstart=` listing
# for all the pids that run (read once per process: a daily prune's hundreds of pids cost one ps,
# not hundreds); a pid it lacks, or no listing (no ps, one without -o): undef. MSYS and Cygwin
# make no listing (their ps has no -o, as _read_start): a running pid there whose stat is not
# readable is undef. There a pid with no /proc folder is a Windows pid (win_probe): its MSYS pid's
# /proc start, else undef while it may run (alive-unknown), 0 once gone; a pid with a /proc folder
# whose number also maps, as a Windows pid, to an MSYS process with another start (win_alt_start)
# is undef. Test mode: STORE_TEST_PROC_STARTS
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
    my $os = util::os();
    my $cyg = $os eq 'msys' || $os eq 'cygwin';
    my $proc = ($os eq 'linux' || $cyg) && -r (_proc() . '/self/stat');
    my @ps;
    for my $p (@want) {
        next if exists $out{$p};
        if ($proc && -r (_proc() . "/$p/stat")) {
            my (undef, undef, $ticks) = _proc_stat($p);
            if (defined $ticks) {
                my $hz = eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
                my $s = POSIX::strftime('%a %b %e %H:%M:%S %Y', localtime(_btime() + int($ticks / $hz)));
                $s =~ s/  / /g;
                $out{$p} = lstart_epoch($s);
                # MSYS and Cygwin: the same number read as a Windows pid may map to another MSYS
                # process (win_alt_start) with another start: which one a record names cannot be
                # told here, so its start is unknown (a record with either start is kept)
                if ($cyg && defined $out{$p}) {
                    my $alt = lstart_epoch(win_alt_start($p));
                    $out{$p} = undef if defined $alt && abs($alt - $out{$p}) > 2;
                }
                next;
            }
        } elsif ($cyg && !-e (_proc() . "/$p")) {
            # a Windows pid (win_probe): its MSYS pid's start, else unknown while it may run
            my ($st, $m) = win_probe($p);
            my (undef, undef, $ticks) = $st eq 'run' ? _proc_stat($m) : ();
            if (defined $ticks) {
                my $hz = eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
                my $s = POSIX::strftime('%a %b %e %H:%M:%S %Y', localtime(_btime() + int($ticks / $hz)));
                $s =~ s/  / /g;
                $out{$p} = lstart_epoch($s);
            } else {
                $out{$p} = $st eq 'gone' ? 0 : undef;
            }
            next;
        } elsif ($proc && !-e (_proc() . "/$p")) {
            $out{$p} = 0;
            next;
        }
        if (!(kill(0, $p) || $!{EPERM})) { $out{$p} = 0; next }
        $out{$p} = undef;
        push @ps, $p;
    }
    if (@ps && !$cyg) {
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
# check, helper cases AT-RS-21 and AT-RS-29).
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
    if ($^O eq 'linux' && -r (_proc() . "/$pid/stat")) {
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
# names (Claude Code sets it to its own pid for hooks). A background session's
# worker runs under a name that hides the binary, so the walk passed it and took its supervisor
# (`claude daemon`), whose pid every background session then shared. So the hops below the
# anchor are checked by their executable first, nearest first; a foreground session's helper,
# whose parent is the anchor, reads none, and with no anchor (a helper run from a terminal) none
# is read either. A hop that CLAUDE_PID names is the anchor before its own parent and command are
# read (0.1.4 T-14): a hook's helper whose parent is Claude Code itself makes no `ps` call here.
# Under MSYS and Cygwin (util::os) a walk that starts at pid 1 or below has no parent chain to read
# (Git Bash's perl sees getppid() = 1 in a hook): CLAUDE_PID is then the anchor, and without it the
# walk finds nothing, as before. Elsewhere a helper whose parent is pid 1 is an orphan, whose
# CLAUDE_PID may name a process that has exited: it finds nothing, as before. Under MSYS and
# Cygwin a walk that cannot climb to Claude Code (a skill's helper under the Bash tool's shells)
# takes CLAUDE_PID too, found, unless that pid is gone.
sub _walk {
    my ($pid) = @_;
    my $env = (defined $ENV{CLAUDE_PID} && $ENV{CLAUDE_PID} =~ /^[1-9][0-9]*$/) ? 0 + $ENV{CLAUDE_PID} : 0;
    if ((!$pid || $pid <= 1) && $env) {
        my $os = util::os();
        return (0 + $env, 1) if $os eq 'msys' || $os eq 'cygwin';
    }
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
    # MSYS and Cygwin: a walk from a Bash-tool shell ends at that shell (their ps has no -o, and a
    # native claude.exe is no MSYS parent), so it would take the transient shell's pid. CLAUDE_PID,
    # the Windows pid the session's records hold, is then the anchor, unless it is gone (win_probe).
    if ($env && cyg()) {
        my ($st) = win_probe($env);
        return (0 + $env, 1) unless $st eq 'gone';
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
# that record names the same pid, else from start_time (one `ps` call off Linux; 0.1.4 T-14;
# under MSYS and Cygwin _claude_start).
sub claude_pid {
    return $CACHED if $CACHED;
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/) {
        # STORE_TEST_CLAUDE_FOUND=0: the walk's verdict when it did not find Claude Code (the pid is then a fallback)
        $CACHED = { pid => 0 + $1, lstart => $2, found => (($ENV{STORE_TEST_CLAUDE_FOUND} // '') eq '0' ? 0 : 1) };
        $START{$1} = $2;
        return $CACHED;
    }
    # STORE_TEST_PPID (test mode): stands in for getppid(), e.g. 1 as Git Bash's perl sees it.
    my $first = util::test_mode() && ($ENV{STORE_TEST_PPID} // '') =~ /\A[0-9]+\z/ ? 0 + $ENV{STORE_TEST_PPID} : getppid();
    # A hook's perl runs as the launcher's child (0.1.4: a perl that cannot start falls
    # back), which hands main.pl "<launcher pid>:<its parent>". While the launcher is still this
    # process's parent the walk starts at that parent, as when perl took the launcher's place: the
    # launcher, a shell, costs no parent read (T-14).
    my $lp = do { no warnings q(once); $main::STORE_LAUNCHER_PARENT };
    $first = 0 + $2 if defined $lp && !ref $lp && $lp =~ /\A([1-9][0-9]*):([1-9][0-9]*)\z/ && $1 == $first;
    my ($pid, $found) = _walk($first);
    $pid //= $first;
    my $d = !$OWN_START && defined &rc::sid_dir ? eval { rc::sid_dir() } : undef;
    my $raw = defined $d ? util::read_file("$d/classic-alive.json", 4096) : undef;
    my $rec = defined $raw ? eval { jsonc::decode($raw) } : undef;
    my $ls = ref $rec eq 'HASH' && defined $rec->{pid} && !ref $rec->{pid} && $rec->{pid} =~ /\A[1-9][0-9]*\z/ && $rec->{pid} == $pid
             && defined $rec->{pid_lstart} && !ref $rec->{pid_lstart} && $rec->{pid_lstart} =~ /\S/ ? $rec->{pid_lstart} : undef;
    $CACHED = { pid => 0 + $pid, lstart => $ls // _claude_start($pid), found => $found };
    return $CACHED;
}

# _claude_start(pid) -> start_time(pid). Under MSYS and Cygwin, for the pid CLAUDE_PID names (Claude
# Code's Windows pid), the start of the MSYS process it maps to comes first (win_alt_start): the same
# number may also be a running MSYS pid with a /proc entry, whose start is not the claude's, and a
# record that held that start would read as ended once that process exits while the claude runs.
sub _claude_start {
    my ($pid) = @_;
    if (cyg() && defined $ENV{CLAUDE_PID} && $ENV{CLAUDE_PID} =~ /\A[1-9][0-9]*\z/ && $ENV{CLAUDE_PID} == $pid) {
        my $s = win_alt_start($pid);
        return $s if defined $s;
    }
    return start_time($pid);
}

# alive(pid, lstart) -> 1 when the pid runs and its start time matches, or cannot be read now
# (alive-unknown): a record that has a start time is never taken as ended on a start time
# this call cannot read (MSYS before its /proc read, a `ps` that timed out under load), so a lock
# holder's record waits out lock-timeout and is never broken. A record without a start time
# rests on kill 0. A caller that acts on the process (a kill, a caller check) asks
# alive_verified instead.
# A Linux record written before the start-time fix holds btime + vsize/HZ in place of the start time.
# It is judged like any other: its pid runs with another start time, so it counts as ended.
# The old code reached the same verdict once the process's size had changed since the
# record was written (its own reading moved with memory); only a record whose process kept its
# size gets another verdict now. Such records matter only while processes started before the
# upgrade still run.
# MSYS and Cygwin: a Windows pid is judged by win_probe (liveness): through its MSYS pid as above,
# and a pid only `ps -W` lists, or one with no listing, is alive-unknown: 1, whatever lstart says.
# A pid with a /proc entry whose start differs is still alive when the same number, read as a
# Windows pid, maps to an MSYS process with the recorded start (win_alt_start).
sub alive {
    my ($pid, $lstart) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    my $lv = liveness($pid);
    return 0 if $lv eq 'gone';
    return 1 if $lv eq 'unknown';
    return 1 unless defined $lstart && $lstart ne '';
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/ && $1 == $pid) {
        return $2 eq $lstart ? 1 : 0;
    }
    my $now = start_time($pid);
    return 1 unless defined $now;
    return 1 if $now eq $lstart;
    return 0 unless cyg();
    my $alt = win_alt_start($pid);
    return defined $alt && $alt eq $lstart ? 1 : 0;
}

# alive_own(pid, lstart) -> alive for a record of a helper process's own pid ($$: a lock holder,
# lib/lock.pm). Under MSYS and Cygwin that is an MSYS pid, never a Windows one, so it is judged by
# MSYS rules only: kill 0 and its own /proc start time, never the winpid map or `ps -W` (a dead
# holder whose number a live Windows process holds would read alive-unknown and its lock would
# never be taken over). Elsewhere it is alive.
sub alive_own {
    my ($pid, $lstart) = @_;
    return alive($pid, $lstart) unless cyg();
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return 0 unless kill(0, $pid) || $!{EPERM};
    return 1 unless defined $lstart && $lstart ne '';
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/ && $1 == $pid) {
        return $2 eq $lstart ? 1 : 0;
    }
    my (undef, $now) = -e (_proc() . "/$pid") ? _read_start($pid) : ();
    return 1 unless defined $now;
    return $now eq $lstart ? 1 : 0;
}

# alive_verified(pid, lstart) -> 1 only when the pid runs and its start time, read now, equals
# lstart: a missing or unreadable start time is never proof that the process is the one recorded
# (an alive-unknown Windows pid gives 0).
sub alive_verified {
    my ($pid, $lstart) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return 0 unless liveness($pid) eq 'run';
    return 0 unless defined $lstart && $lstart ne '';
    if (util::test_mode() && defined $ENV{STORE_TEST_CLAUDE_PID} && $ENV{STORE_TEST_CLAUDE_PID} =~ /^(\d+):(.*)$/ && $1 == $pid) {
        return $2 eq $lstart ? 1 : 0;
    }
    my $now = start_time($pid);
    return defined $now && $now eq $lstart ? 1 : 0;
}

# launcher_above(pid, launcher, max) -> 'ok', 'nested' or 'not-ancestor':
# the walk from pid's parent up at most max processes reaches the launcher pid with no
# process whose command is the Claude Code binary between them. A wrapper (an account switcher, node, a
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

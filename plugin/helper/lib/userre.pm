package userre;
# lib/userre.pm: the user's own regular expressions, matched with a wall-clock bound (U-06,
# REVIEW-NIGHT-2). Owner: WP-core.
#
# A pattern from a setting (secret_extra_rules HARD/WARN, prod_patterns, ticket_pattern,
# relaunch_allow, protected_branches, deny_class_patterns) can backtrack for hours on a large
# file or a long name, and a length cap does not prevent it: `(a+)+$` on a 100 KB run of `a`,
# or ten `[^/]*` in a row on a 200-character name. The match therefore runs in a forked child
# that the helper kills when one pattern runs longer than its limit ($LIMIT_S, set by the caller
# from its own timeout; ticket_pattern has a fixed one, %KEY_LIMIT_S, so every process gives a
# branch the same ticket). The child's clock starts when it says it is ready, so the time to fork
# and be scheduled is not the pattern's. The child also arms its own alarm with the default
# action before each pattern, so the kernel ends it when the helper is gone, and it keeps no
# descriptor of the helper's but its answer pipe (no stdout, no lock).
#
# The process has one budget ($BUDGET_S) for all the time spent in pattern children, whether
# the patterns finished or not: many patterns that each stay under the limit stop when it is
# spent, so a hook stays inside its timeout. A child's first $FREE_S seconds of starting (the
# fork, a few milliseconds) are not counted, so a process that makes many quick calls does not
# use the budget up on forks; a slower start counts. A pattern that is stopped, or not run
# (budget spent, no fork), takes its setting's safe side, which the caller decides: a secret
# rule counts as a hit of its class, a production pattern or a protected branch counts as a
# match, a ticket pattern gives no ticket, a relaunch_allow or deny_class_patterns entry does
# not match. Why: `timeout` (the pattern used at least half its limit in CPU: it is slow),
# `load` (it did not: the machine was busy; tried once more, then the safe side for that call
# only, so a busy machine never marks a pattern slow for the session), `budget`, `error`. A `timeout` pattern is not run again in this process, nor in a
# later one of the session (a marker in the session's once/ folder, by key and the pattern's
# sha256, never the pattern). Each (key, position, why) writes one `regex_timeout {key, index,
# why}` row per session and /status prints a warning for it. With no user pattern nothing
# forks; a call that runs some costs one fork (a few milliseconds), and the same call again is
# answered from memory.
#
# Without Time::HiRes (Debian's perl-base) the clock counts the time select waited (Linux says
# how much of the timeout is left) and the child's CPU time, and never reads more than really
# passed, so no pattern is stopped before its limit.
#
# Entries: [{re => compiled regex, at => 1-based position in the setting}].
use strict;
use warnings;
use utf8;
use POSIX ();

our $LIMIT_S = 1;      # one pattern on one call
our $BUDGET_S = 3;     # this process's time in pattern children, all of it; then they take the safe side unrun
our $START_S = 1;      # a child not ready by then (a busy machine) is stopped as `load`
our $FREE_S = 0.05;    # the part of a child's start the budget does not count
our $CPU_SHARE = 0.5;  # a stop is the pattern's (`timeout`) when it used this share of its limit in CPU
our %KEY_LIMIT_S = (ticket_pattern => 0.25);    # whoever calls: the subject is at most 256 characters
# [limit, budget] for the subcommands the mod calls with a short timeout (main.pl; hooks.ts
# HELPER_MS 2 s, REMEASURE_MS 3 s, SWEEP_MS 10 s, CHECKPOINT_MS 12 s); hooks: cmd/hook.pl %REGEX_S
our %SUB_S = (map({ $_ => [0.25, 0.4] } qw(log ident dispatch prev-copy claim notice handoff-turn handoff-state)),
              measure => [0.5, 0.6], sweep => [1, 2], 'save-copy' => [1, 2], checkpoint => [1, 2]);
our @STOPPED;          # [key, at, why], one per key and position, in order
our $SPENT = 0;        # seconds spent in pattern children
my %SLOW;              # "key\0pattern" => 1 once a run of it was stopped as slow (0: checked, not slow)
my %noted;
my (%MEMO, $MEMO_BIG);
our $MEMO_MAX = 64;
our $MEMO_KEY_MAX = 4096;    # a longer key (a scanned text) is kept alone, the last one only

my ($HAVE_HIRES, $MONO);
sub _hires {
    $HAVE_HIRES //= eval { require Time::HiRes; 1 } ? 1 : 0;
    return 0 if ($ENV{STORE_TEST_MODE} // '') eq '1' && ($ENV{STORE_TEST_NO_HIRES} // '') eq '1';
    return $HAVE_HIRES;
}
sub _now {
    return time() unless _hires();
    $MONO //= eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 } ? 1 : 0;
    return $MONO ? Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) : Time::HiRes::time();
}

# _watch() -> {el => sub: seconds since it started, wait => sub(rin, s): (n, rout), floor =>
# sub(s): at least s have passed}. Without Time::HiRes it adds up what select waited (the whole
# timeout when it timed out; on Linux, the timeout less what select left in it) and reads at
# least the whole seconds time() moved past one and the child's CPU time (floor); none of them
# exceeds the real time.
sub _watch {
    if (_hires()) {
        my $t0 = _now();
        return { el => sub { _now() - $t0 }, floor => sub { }, wait => sub { my $n = select(my $ro = $_[0], undef, undef, $_[1]); return ($n, $ro) } };
    }
    my ($t0, $sum, $low, $linux) = (time(), 0, 0, $^O eq 'linux');
    return {
        el => sub { my $w = time() - $t0 - 1; $w = $sum if $sum > $w; return $low > $w ? $low : $w },
        floor => sub { $low = $_[0] if $_[0] > $low },
        wait => sub {
            my ($rin, $s) = @_;
            my ($n, $tl) = select(my $ro = $rin, undef, undef, $s);
            if ($n == 0) { $sum += $s }
            elsif ($linux && defined $tl && $tl >= 0 && $tl <= $s) { $sum += $s - $tl }
            return ($n, $ro);
        },
    };
}

# limits(limit_s, budget_s): a hook or a subcommand sets both from its own timeout
sub limits { my ($l, $b) = @_; $LIMIT_S = $l if defined $l && $l > 0; $BUDGET_S = $b if defined $b && $b >= 0; return }

# clear(): forget the stopped patterns, the time spent and the answers kept (tests); the
# session's markers stay
sub clear { $SPENT = 0; %SLOW = (); %noted = (); @STOPPED = (); %MEMO = (); $MEMO_BIG = undef; return }

sub _note {
    my ($key, $at, $why) = @_;
    push @STOPPED, [$key, $at, $why] unless $noted{"$key.$at"}++;
    return unless defined &rc::emit && defined &rc::once;
    eval { rc::emit('regex_timeout', [key => $key, index => $at, why => $why]) if rc::once("regex_timeout.$key.$at.$why"); 1 };
    return;
}

sub _write_all {
    my ($fh, $s) = @_;
    my $off = 0;
    while ($off < length $s) {
        my $n = syswrite($fh, $s, length($s) - $off, $off);
        return 0 unless defined $n && $n > 0;
        $off += $n;
    }
    return 1;
}

sub _arm { my ($s) = @_; if (_hires()) { Time::HiRes::alarm($s) } else { alarm(int($s) + 1) } }

# the session's marker for a slow pattern (once/regex_slow.<key>.<sha256 of the pattern, 16>)
sub _marker {
    my ($key, $e) = @_;
    return undef unless defined &rc::sid_dir && defined &sha::hex256;
    my $d = eval { rc::sid_dir() } // return undef;
    return ($d, 'regex_slow.' . $key . '.' . substr(sha::hex256("$e->{re}"), 0, 16));
}
sub _slow {
    my ($key, $e) = @_;
    my $k = $key . "\0" . $e->{re};
    return $SLOW{$k} if defined $SLOW{$k};
    my ($d, $name) = _marker($key, $e);
    return $SLOW{$k} = (defined $d && -e "$d/once/$name") ? 1 : 0;
}
sub _mark_slow {
    my ($key, $e) = @_;
    $SLOW{ $key . "\0" . $e->{re} } = 1;
    my ($d, $name) = _marker($key, $e);
    eval { rc::once($name) } if defined $d && defined &rc::once;
    return;
}

# _detach(keep): in the child, stdin, stdout and stderr on /dev/null and every other descriptor
# closed but keep's, so a child the helper's killer missed holds no pipe or lock of the helper's
sub _detach {
    my ($keep) = @_;
    my $kf = fileno($keep);
    my $null = POSIX::open('/dev/null', POSIX::O_RDWR());
    if (defined $null) { POSIX::dup2($null, $_) for 0 .. 2; POSIX::close($null) if $null > 2 }
    my @fd;
    for my $dir ('/proc/self/fd', '/dev/fd') {
        opendir(my $dh, $dir) or next;
        @fd = grep { /\A[0-9]+\z/ } readdir $dh;
        closedir $dh;
        last if @fd;
    }
    if (!@fd) {
        my $max = eval { POSIX::sysconf(POSIX::_SC_OPEN_MAX()) };
        $max = 1024 unless defined $max && $max > 3 && $max <= 1024;
        @fd = 3 .. $max - 1;
    }
    POSIX::close($_) for grep { $_ > 2 && $_ != $kf } @fd;
    return;
}

# _child(entries, from, to, job, until, limit, cap) -> {got => \%values by index, miss => index
# not answered | undef, why, ended => 0|1, cost => seconds from fork to reap less the free part
# of the start}: entries from..to in one child; no entry runs past `limit` and the cost not past
# `cap`.
sub _child {
    my ($entries, $from, $to, $job, $until, $limit, $cap) = @_;
    my $sw = _watch();
    my $free = sub { my $t = defined $_[0] ? $_[0] : $sw->{el}->(); return $t < $FREE_S ? $t : $FREE_S };
    my $fail = sub { return { got => {}, miss => $from, why => 'error', ended => 0, cost => $sw->{el}->() - $free->() } };
    pipe(my $r, my $w) or return $fail->();
    my $pid = fork();
    if (!defined $pid) { close $r; close $w; return $fail->() }
    if ($pid == 0) {
        close $r;
        $SIG{$_} = 'DEFAULT' for qw(ALRM PIPE TERM INT HUP);
        _arm($START_S + $limit + 0.5);
        _detach($w);
        my $cpu = sub { my @t = times; return int(($t[0] + $t[1]) * 1000) };
        my $ok = eval {
            _write_all($w, 'R ' . $cpu->() . "\n") or POSIX::_exit(1);
            for my $k ($from .. $to) {
                _arm($limit + 0.5);
                my @v = $job->($entries->[$k]);
                _write_all($w, join(' ', $k, $cpu->(), map { defined $_ ? $_ : -1 } @v) . "\n") or POSIX::_exit(1);
                last if $until && $until->(\@v);
            }
            1;
        };
        POSIX::_exit($ok ? 0 : 1);
    }
    close $w;
    # killed while a pattern runs (a hook timeout): take the child along, as util::run does
    local $SIG{TERM} = sub { kill 'KILL', $pid; POSIX::_exit(128 + 15) };
    local $SIG{HUP} = sub { kill 'KILL', $pid; POSIX::_exit(128 + 1) };
    local $SIG{INT} = sub { kill 'KILL', $pid; POSIX::_exit(128 + 2) };
    my @t0 = times;
    my (%got, $why, $eof, $ended, $since, $ready);
    my ($buf, $scan, $rin, $cpu_at) = ('', 0, '', 0);
    vec($rin, fileno($r), 1) = 1;
    while (1) {
        my ($end, $what) = defined $since ? ($since + $limit, 'timeout') : ($START_S, 'load');
        my $bend = $cap + (defined $ready ? $free->($ready) : $FREE_S);
        ($end, $what) = ($bend, 'budget') if $bend < $end;
        my $left = $end - $sw->{el}->();
        if ($left <= 0) { $why = $what; last }
        my ($n) = $sw->{wait}->($rin, $left);
        if ($n < 0) { next if $!{EINTR}; last }
        next if $n == 0;
        my $len = sysread($r, my $chunk, 1 << 16);
        if (!defined $len) { next if $!{EINTR}; last }
        if ($len == 0) { $eof = 1; last }
        $buf .= $chunk;
        while ((my $nl = index($buf, "\n", $scan)) >= 0) {
            my @v = split / /, substr($buf, 0, $nl);
            substr($buf, 0, $nl + 1) = '';
            $scan = 0;
            my ($k, $c) = splice(@v, 0, 2);
            $cpu_at = $c // 0;
            $sw->{floor}->($cpu_at / 1000);
            $since = $sw->{el}->();
            $ready //= $since;
            next if $k eq 'R';
            $got{$k} = [ map { $_ == -1 ? undef : $_ } @v ];
            $ended = 1 if $until && $until->($got{$k});
        }
        $scan = length $buf;
    }
    close $r;
    kill 'KILL', $pid unless $eof;
    waitpid($pid, 0);
    my $status = $?;
    my @t1 = times;
    my $cpu_all = ($t1[2] + $t1[3]) - ($t0[2] + $t0[3]);
    $sw->{floor}->($cpu_all);
    my $el = $sw->{el}->();
    my $res = { got => \%got, ended => $ended ? 1 : 0, cost => $el - $free->(defined $ready ? $ready : $el) };
    return $res if $ended;
    my ($miss) = grep { !$got{$_} } $from .. $to;
    return $res unless defined $miss;
    # the child's own alarm (the helper's clock read short of the limit): a timeout
    $why //= ($eof && ($status & 127) == 14) ? 'timeout' : 'error';
    if ($why eq 'timeout') {
        my $cpu = $cpu_all - $cpu_at / 1000;
        $why = 'load' if $cpu < $limit * $CPU_SHARE;
    }
    return { %$res, miss => $miss, why => $why };
}

# run(key, \@entries, job[, until => sub(\@values), halt => 0|1, memo => text]) -> (\@values,
# \@stopped): job(entry) runs in the child and returns a list of integers (undef allowed);
# $values[i] is that list for entry i, or undef when the entry was stopped or not run (then its
# index is in @stopped). `until` ends the run after the first entry whose values it accepts;
# `halt` ends it at the first stopped entry (when that already decides the caller's answer).
# `memo`: the same key, entries and memo text answer from memory (the caller names the input).
sub run {
    my ($key, $entries, $job, %o) = @_;
    my $n = ref $entries eq 'ARRAY' ? scalar @$entries : 0;
    return ([], []) unless $n;
    my $mk = defined $o{memo} ? join("\0", $key, (map { "$_->{re}" } @$entries), $o{memo}) : undef;
    if (defined $mk) {
        return @{ $MEMO{$mk} } if length($mk) <= $MEMO_KEY_MAX && $MEMO{$mk};
        return @{ $MEMO_BIG->[1] } if length($mk) > $MEMO_KEY_MAX && $MEMO_BIG && $MEMO_BIG->[0] eq $mk;
    }
    my $limit = $KEY_LIMIT_S{$key} // $LIMIT_S;
    my (@res, @stopped, %again);
    my $i = 0;
    while ($i < $n) {
        my $e = $entries->[$i];
        my $left = $BUDGET_S - $SPENT;
        if (_slow($key, $e) || $left <= 0.01) {
            _note($key, $e->{at} // $i + 1, _slow($key, $e) ? 'timeout' : 'budget');
            push @stopped, $i;
            last if $o{halt};
            $i++;
            next;
        }
        my $j = $i;
        $j++ while $j + 1 < $n && !_slow($key, $entries->[$j + 1]);
        my $c = _child($entries, $i, $j, $job, $o{until}, $limit, $left);
        $SPENT += $c->{cost};
        $res[$_] = $c->{got}{$_} for keys %{ $c->{got} };
        last if $c->{ended};
        my $miss = $c->{miss};
        if (!defined $miss) { $i = $j + 1; next }
        # a busy machine is not a slow pattern: once more, then the safe side for this call
        if ($c->{why} eq 'load' && !$again{$miss}++) { $i = $miss; next }
        _mark_slow($key, $entries->[$miss]) if $c->{why} eq 'timeout';
        _note($key, $entries->[$miss]{at} // $miss + 1, $c->{why});
        push @stopped, $miss;
        last if $o{halt};
        $i = $miss + 1;
    }
    if (defined $mk) {
        if (length($mk) > $MEMO_KEY_MAX) { $MEMO_BIG = [$mk, [\@res, \@stopped]] }
        else { %MEMO = () if keys %MEMO >= $MEMO_MAX; $MEMO{$mk} = [\@res, \@stopped] }
    }
    return (\@res, \@stopped);
}

# first(key, \@entries, \@subjects, safe) -> the index of the first entry that matches any of
# the subjects, else undef. safe `match`: a stopped entry counts as a match (prod_patterns,
# protected_branches); safe `skip`: it does not (relaunch_allow, deny_class_patterns).
sub first {
    my ($key, $entries, $subjects, $safe) = @_;
    return undef unless ref $entries eq 'ARRAY' && @$entries;
    my @subj = grep { defined && !ref } @{ ref $subjects eq 'ARRAY' ? $subjects : [$subjects] };
    my $hit = ($safe // '') eq 'match';
    my ($res, $stopped) = run($key, $entries, sub { my $re = $_[0]{re}; for (@subj) { return 1 if $_ =~ $re } return 0 },
                              until => sub { $_[0][0] }, halt => $hit, memo => join("\0", "first.$hit", map { length($_) . ":$_" } @subj));
    my %st = map { $_ => 1 } @$stopped;
    for my $i (0 .. $#$entries) {
        return $i if $res->[$i] && $res->[$i][0];
        return $i if $hit && $st{$i};
    }
    return undef;
}

# capture(key, entry, subject) -> ('ok', [start0, end0, start1, end1]) after a match (group 1
# undef when the pattern has none or it did not take part), ('ok', undef) when it does not
# match, ('stopped') when it was stopped or not run.
sub capture {
    my ($key, $e, $s) = @_;
    my ($res, $stopped) = run($key, [$e], sub {
        my $re = $_[0]{re};
        return (0) unless $s =~ $re;
        return (1, $-[0], $+[0], (@- > 1 && defined $-[1] ? ($-[1], $+[1]) : (undef, undef)));
    }, memo => "capture\0$s");
    return ('stopped') if @$stopped || !$res->[0];
    my @v = @{ $res->[0] };
    return ('ok', undef) unless $v[0];
    return ('ok', [@v[1 .. 4]]);
}

1;

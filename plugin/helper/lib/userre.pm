package userre;
# lib/userre.pm: the user's own regular expressions, matched with a wall-clock bound (U-06,
# REVIEW-NIGHT-2). Owner: WP-core.
#
# A pattern from a setting (secret_extra_rules HARD/WARN, prod_patterns, ticket_pattern,
# relaunch_allow, protected_branches, deny_class_patterns) can backtrack for hours on a large
# file or a long name, and a length cap does not prevent it: `(a+)+$` on a 100 KB run of `a`,
# or ten `[^/]*` in a row on a 200-character name. The match therefore runs in a forked child
# that the helper kills when one pattern takes longer than $LIMIT_S; the child also arms its own
# alarm with the default action before each pattern, so the kernel ends it even when the helper
# is gone. A pattern that is stopped, or not run because this process already lost $BUDGET_S
# seconds to stopped patterns or cannot fork, takes its setting's safe side, which the caller
# decides: a secret rule withholds, a production pattern or a protected branch counts as a
# match, a ticket pattern gives no ticket, a relaunch_allow or deny_class_patterns entry does not
# match. Each writes one `regex_timeout {key, index, why}` row per session (why: timeout |
# budget | error; the row never holds the pattern) and /status prints a warning for it. A
# pattern stopped once is not run again in this process. With no user pattern nothing forks;
# a call that runs some costs one fork (a few milliseconds), and the same call again is answered from
# memory.
#
# Entries: [{re => compiled regex, at => 1-based position in the setting}].
use strict;
use warnings;
use utf8;
use POSIX ();

our $LIMIT_S = 1;     # one pattern on one call
our $BUDGET_S = 3;    # this process's time lost to stopped patterns; then they take the safe side unrun
our @STOPPED;         # [key, at, why], one per key and position, in order
my $lost = 0;
my %SLOW;             # "key\0pattern" => 1 once a run of it was stopped
my %noted;
my (%MEMO, $MEMO_BIG);
our $MEMO_MAX = 64;
our $MEMO_KEY_MAX = 1 << 20;

my $HIRES;
sub _now { $HIRES //= eval { require Time::HiRes; 1 } ? 1 : 0; return $HIRES ? Time::HiRes::time() : time() }

# limits(limit_s, budget_s): a hook sets both from its own timeout (cmd/hook.pl)
sub limits { my ($l, $b) = @_; $LIMIT_S = $l if defined $l && $l > 0; $BUDGET_S = $b if defined $b && $b >= 0; return }

# clear(): forget the stopped patterns, the time lost and the answers kept (tests)
sub clear { $lost = 0; %SLOW = (); %noted = (); @STOPPED = (); %MEMO = (); $MEMO_BIG = undef; return }

sub _note {
    my ($key, $at, $why) = @_;
    push @STOPPED, [$key, $at, $why] unless $noted{"$key.$at"}++;
    return unless defined &rc::emit && defined &rc::once;
    eval { rc::emit('regex_timeout', [key => $key, index => $at, why => $why]) if rc::once("regex_timeout.$key.$at"); 1 };
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

sub _arm { my ($s) = @_; if ($HIRES) { Time::HiRes::alarm($s) } else { alarm(int($s) + 1) } }

sub _slow { my ($key, $e) = @_; return $SLOW{ $key . "\0" . $e->{re} } }

# _child(entries, from, to, job, until, limit) -> (\%values by index, index not answered | undef,
# why, seconds that entry ran, until-ended 0|1): entries from..to in one child.
sub _child {
    my ($entries, $from, $to, $job, $until, $limit) = @_;
    _now();
    pipe(my $r, my $w) or return ({}, $from, 'error', 0, 0);
    my $pid = fork();
    if (!defined $pid) { close $r; close $w; return ({}, $from, 'error', 0, 0) }
    if ($pid == 0) {
        close $r;
        $SIG{$_} = 'DEFAULT' for qw(ALRM PIPE TERM INT HUP);
        my $ok = eval {
            for my $k ($from .. $to) {
                _arm($limit + 0.5);
                my @v = $job->($entries->[$k]);
                _write_all($w, join(' ', $k, map { defined $_ ? $_ : -1 } @v) . "\n") or POSIX::_exit(1);
                last if $until && $until->(\@v);
            }
            1;
        };
        POSIX::_exit($ok ? 0 : 1);
    }
    close $w;
    my (%got, $timed_out, $eof, $ended);
    my ($buf, $scan, $rin) = ('', 0, '');
    vec($rin, fileno($r), 1) = 1;
    my $since = _now();
    my $deadline = $since + $limit;
    while (1) {
        my $left = $deadline - _now();
        if ($left <= 0) { $timed_out = 1; last }
        my $n = select(my $rout = $rin, undef, undef, $left);
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
            my $k = shift @v;
            $got{$k} = [ map { $_ == -1 ? undef : $_ } @v ];
            $ended = 1 if $until && $until->($got{$k});
            $since = _now();
            $deadline = $since + $limit;
        }
        $scan = length $buf;
    }
    close $r;
    kill 'KILL', $pid unless $eof;
    waitpid($pid, 0);
    return (\%got, undef, undef, 0, 1) if $ended;
    my ($miss) = grep { !$got{$_} } $from .. $to;
    return (\%got, undef, undef, 0, 0) unless defined $miss;
    return (\%got, $miss, ($timed_out ? 'timeout' : 'error'), _now() - $since, 0);
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
    my (@res, @stopped);
    my $i = 0;
    while ($i < $n) {
        my $e = $entries->[$i];
        if (_slow($key, $e) || $lost >= $BUDGET_S) {
            _note($key, $e->{at} // $i + 1, _slow($key, $e) ? 'timeout' : 'budget');
            push @stopped, $i;
            last if $o{halt};
            $i++;
            next;
        }
        my $j = $i;
        $j++ while $j + 1 < $n && !_slow($key, $entries->[$j + 1]);
        my $left = $BUDGET_S - $lost;
        my $limit = $LIMIT_S < $left ? $LIMIT_S : $left;
        $limit = 0.05 if $limit < 0.05;
        my ($got, $miss, $why, $cost, $ended) = _child($entries, $i, $j, $job, $o{until}, $limit);
        $res[$_] = $got->{$_} for keys %$got;
        last if $ended;
        if (!defined $miss) { $i = $j + 1; next }
        $lost += $cost;
        $SLOW{ $key . "\0" . $entries->[$miss]{re} } = 1 if $why eq 'timeout';
        _note($key, $entries->[$miss]{at} // $miss + 1, $why);
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

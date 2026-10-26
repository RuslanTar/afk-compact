#!/usr/bin/perl
# U-06 at the perl floor (Linux, in Docker; run by tests/helper/run.pl builtin linux_start_time):
# lib/userre.pm with the clock it has there (debian:buster-slim's perl-base has no Time::HiRes).
# Wall time comes from `date +%s.%N`. Prints `FAIL: ` lines and ends with `DONE`.
use strict;
use warnings;
use POSIX ();
use Fcntl qw(:flock);
unshift @INC, '/w/helper/lib';
require "userre.pm";
my $hires = eval { require Time::HiRes; 1 } ? 1 : 0;
my $fails = 0;
sub fail { print "FAIL: $_[0]\n"; $fails++ }
sub wall { my $t = `date +%s.%N`; chomp $t; return $t + 0 }
sub kids {
    my ($pp) = @_;
    my @k;
    opendir(my $d, '/proc') or return ();
    for my $p (grep { /\A\d+\z/ } readdir $d) {
        open(my $fh, '<', "/proc/$p/stat") or next;
        my $s = <$fh>;
        close $fh;
        push @k, $p if defined $s && $s =~ /\)\s+\S\s+(\d+)/ && $1 == $pp;
    }
    return @k;
}
sub gone { my ($p) = @_; open(my $fh, '<', "/proc/$p/stat") or return 1; my $s = <$fh>; return $s =~ /\)\s+Z/ ? 1 : 0 }
{ no warnings "once"; $userre::CPU_SHARE = 0 }    # every stop is the pattern's, whatever the machine's load
print "perl $] hires=$hires\n";
my $long = ('a' x 100_000) . 'b';

# a stopped pattern: within its limit, why timeout
for my $l (0.25, 1) {
    userre::clear();
    userre::limits($l, 5);
    my $t0 = wall();
    my $k = userre::first('prod_patterns', [{ re => qr/(a+)+$/, at => 1 }], ["echo $long"], 'match');
    my $dt = wall() - $t0;
    my $why = join(',', map { $_->[2] } @userre::STOPPED);
    printf "limit %s: stopped after %.3f s, why %s\n", $l, $dt, $why;
    fail("limit $l: answer " . ($k // 'undef') . ', want 0 (production)') unless defined $k && $k == 0;
    fail("limit $l: why [$why], want timeout") unless $why eq 'timeout';
    fail(sprintf('limit %s: stopped after %.3f s, before its limit', $l, $dt)) if $dt < $l;
    fail(sprintf('limit %s: stopped after %.3f s, want under %.2f', $l, $dt, $l + 0.6)) if $dt > $l + 0.6;
}

# a many-match answer (60,000 spans, read in many chunks) is never stopped
{
    my $text = join(' ', map { "tok$_" } 1 .. 60_000);
    my $stops = 0;
    for my $i (1 .. 20) {
        userre::clear();
        userre::limits(0.5, 100);
        my ($res, $st) = userre::run('secret_extra_rules', [{ re => qr/tok\d+/, at => 1 }], sub {
            my @p; while ($text =~ /$_[0]{re}/g) { push @p, $-[0], $+[0] } return (scalar(@p) / 2, @p) }, memo => "m$i");
        $stops++ if @$st;
    }
    print "many-match: 20 calls, $stops stopped\n";
    fail("many-match: $stops of 20 calls stopped") if $stops;
}

# the budget counts all the time: twenty patterns that each finish under the limit
{
    my $n = 300;
    while ($n < 400_000) {
        my $s = ('a' x $n) . 'b';
        my $t0 = wall();
        my $x = $s =~ /(a+)+$/;
        last if wall() - $t0 >= 0.08;
        $n = int($n * 1.4);
    }
    my $subj = ('a' x $n) . 'b';
    userre::clear();
    userre::limits(0.25, 0.4);
    my @e = map { my $c = "(?#$_)"; +{ re => qr/(a+)+$c$/, at => $_ } } 1 .. 20;
    my $t0 = wall();
    my $k = userre::first('deny_class_patterns', \@e, [$subj], 'skip');
    my $dt = wall() - $t0;
    my $b = grep { $_->[2] eq 'budget' } @userre::STOPPED;
    printf "total: n=%d, 20 patterns took %.3f s, %d not run\n", $n, $dt, $b;
    fail(sprintf('total: 20 patterns took %.3f s, over 0.8', $dt)) if $dt > 0.8;
    fail('total: none was left unrun') unless $b;
}

# the helper killed (KILL) or stopped (TERM) mid-match: the child ends; it holds no lock
for my $sig ('KILL', 'TERM') {
    my $f = "/tmp/u06-lock-$$";
    my $pid = fork();
    if ($pid == 0) {
        open(my $lk, '>', $f) or POSIX::_exit(2);
        flock($lk, LOCK_EX) or POSIX::_exit(3);
        userre::clear();
        userre::limits(1, 3);
        userre::first('relaunch_allow', [{ re => qr/^(a+)+$/, at => 1 }], [$long], 'skip');
        POSIX::_exit(0);
    }
    select(undef, undef, undef, 0.3);
    my @g = kids($pid);
    kill $sig, $pid;
    waitpid($pid, 0);
    open(my $lk, '>', $f) or die "open $f: $!";
    fail("$sig: the helper's lock is held after it ended") unless flock($lk, LOCK_EX | LOCK_NB);
    close $lk;
    unlink $f;
    fail("$sig: no pattern child under the helper") unless @g;
    my $t0 = wall();
    select(undef, undef, undef, 0.02) while wall() - $t0 < 3 && grep { !gone($_) } @g;
    my $dt = wall() - $t0;
    printf "%s: the pattern child ended %.2f s after its helper\n", $sig, $dt;
    fail(sprintf('%s: the pattern child still runs %.2f s after its helper', $sig, $dt)) if grep { !gone($_) } @g;
    fail(sprintf('TERM: the pattern child ended %.2f s after its helper, want with it', $dt)) if $sig eq 'TERM' && $dt > 0.3;
}
print "DONE $fails\n";

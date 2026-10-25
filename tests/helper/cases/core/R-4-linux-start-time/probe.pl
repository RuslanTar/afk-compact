# R-4 probe: run inside a Linux container as `perl - MB STEPS` with the plugin's helper/ at
# /w/helper (read-only), offline, TZ=UTC, LC_ALL=C (tests/helper/run.pl builtin linux_start_time).
# A child (comm with a space and parentheses) allocates MB MiB STEPS times; before each step and
# after the last, a fresh perl reads identity::start_time(child) (a fresh process each time:
# identity caches a pid's start time per process). Every reading must be the same, lie within
# the fork's second (+-2 s), equal `ps -o lstart=` where the image has ps, and the child's
# /proc field 23 (vsize) must have grown, so the readings span a real change in memory. The
# probe's own pid is checked against ps and the clock as well. Prints `FAIL: ` lines and a
# final `DONE` line; exits 1 on any failure.
use strict;
use warnings;
use POSIX ();

my ($MB, $STEPS) = (@ARGV, 32, 3);
my $LIB = '/w/helper/lib';
$SIG{ALRM} = sub { print "FAIL: the probe ran out of its 90 s\n"; POSIX::_exit(3) };
alarm 90;
$| = 1;
my ($checks, $fails) = (0, 0);
sub check { my ($ok, $what) = @_; $checks++; if ($ok) { print "ok $what\n" } else { $fails++; print "FAIL: $what\n" } return $ok }

sub slurp { my ($p) = @_; open(my $f, '<:raw', $p) or return undef; local $/; my $r = <$f>; close $f; return $r }
sub vsize {
    my ($pid) = @_;
    my $raw = slurp("/proc/$pid/stat") // return undef;
    my @f = split ' ', substr($raw, rindex($raw, ')') + 2);    # fields from 3 (state) on
    return $f[20];
}
sub fresh_start {
    my ($pid) = @_;
    my $code = 'require "util.pm"; require "identity.pm"; my $s = identity::start_time($ARGV[0]); '
             . 'my $e = identity::lstart_epoch($s); print defined $s ? "$s\t" . (defined $e ? $e : "") : "undef"';
    open(my $fh, '-|', $^X, "-I$LIB", '-e', $code, $pid) or return ('undef', undef);
    local $/;
    my $out = <$fh> // '';
    close $fh;
    my ($s, $e) = split /\t/, $out, 2;
    return ($s, (defined $e && $e =~ /\A\d+\z/ ? $e : undef));
}
my $PS = -x '/usr/bin/ps' ? '/usr/bin/ps' : -x '/bin/ps' ? '/bin/ps' : undef;
sub ps_lstart {
    my ($pid) = @_;
    return undef unless $PS;
    open(my $fh, '-|', $PS, '-o', 'lstart=', '-p', $pid) or return undef;
    local $/;
    my $s = <$fh> // '';
    close $fh;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/\s+/ /g;
    return $s eq '' ? undef : $s;
}

print "# perl $] on " . join(' ', (POSIX::uname())[0, 2, 4]) . '; ps ' . ($PS ? 'present' : 'absent: no ps comparison') . "\n";

# the probe itself: started before this line, so within [btime, now]
{
    my ($s, $e) = fresh_start($$);
    check(defined $e, "probe pid $$: start_time '$s' parses");
    check(defined $e && $e <= time() + 1 && $e >= time() - 120, "probe pid $$: start_time '$s' lies in the last 2 minutes");
    if ($PS) { my $p = ps_lstart($$) // 'none'; check($s eq $p, "probe pid $$: start_time '$s' equals ps -o lstart= '$p'") }
}

pipe(my $cmd_r, my $cmd_w) or die "pipe: $!";
pipe(my $ack_r, my $ack_w) or die "pipe: $!";
my $t0 = time();
my $kid = fork() // die "fork: $!";
if ($kid == 0) {
    close $cmd_w;
    close $ack_r;
    $0 = 'r4 hog (mem)';
    my @hog;
    syswrite($ack_w, 'r');
    while (sysread($cmd_r, my $b, 1)) {
        push @hog, 'x' x ($MB * 1024 * 1024);
        syswrite($ack_w, 'a');
    }
    POSIX::_exit(0);
}
my $t1 = time();
close $cmd_r;
close $ack_w;
sysread($ack_r, my $b0, 1);
my (@seen, @vs);
for my $i (0 .. $STEPS) {
    my ($s, $e) = fresh_start($kid);
    push @seen, $s;
    push @vs, vsize($kid) // 0;
    check(defined $e, "child step $i: start_time '$s' parses");
    check(defined $e && $e >= $t0 - 2 && $e <= $t1 + 2, "child step $i (vsize $vs[-1]): start_time '$s' lies within the fork's second ($t0..$t1, +-2 s)");
    if ($PS) { my $p = ps_lstart($kid) // 'none'; check($s eq $p, "child step $i: start_time '$s' equals ps -o lstart= '$p'") }
    last if $i == $STEPS;
    syswrite($cmd_w, 'm');
    sysread($ack_r, my $b, 1);
}
check($vs[-1] - $vs[0] >= $MB * 1024 * 1024 * $STEPS / 2, "child vsize grew from $vs[0] to $vs[-1] (the readings span a change in memory)");
my %u = map { ($_ => 1) } @seen;
check(keys(%u) == 1, 'start_time stayed the same while the child allocated: ' . join(' | ', map { "'$_'" } @seen));
close $cmd_w;
waitpid($kid, 0);
print "DONE checks=$checks fails=$fails\n";
exit($fails ? 1 : 0);

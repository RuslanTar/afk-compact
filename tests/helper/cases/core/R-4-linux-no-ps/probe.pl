# R-4 probe without ps: run inside a Linux container that has no ps (no procps) as
# `perl - MB STEPS` (both ignored) with the plugin's helper/ at /w/helper (read-only), offline,
# TZ=UTC, LC_ALL=C (tests/helper/run.pl builtin linux_start_time). Every start-time reader of
# the helper must read /proc there, not report "unknown": identity::start_epoch and start_time
# (one reading), skills::core::lstart (the skills' record format), skills::ctx::pid_state (match
# / gone), identity::alive, and the wait helper's pid check (skills::wait::_pid_state: a live
# pid anchored at another start is `reused`, at its own start `alive`; an ended one `gone`).
# Before the fix the wait helper and skills::core read `ps -o lstart=` only, so on such an image
# a live pid at any start read `alive`. Prints `FAIL: ` lines and a final `DONE` line; exits 1
# on any failure.
use strict;
use warnings;
use POSIX ();

my $LIB = '/w/helper/lib';
unshift @INC, $LIB;
$SIG{ALRM} = sub { print "FAIL: the probe ran out of its 60 s\n"; POSIX::_exit(3) };
alarm 60;
$| = 1;
my ($checks, $fails) = (0, 0);
sub check { my ($ok, $what) = @_; $checks++; if ($ok) { print "ok $what\n" } else { $fails++; print "FAIL: $what\n" } return $ok }
sub show { my ($v) = @_; return defined $v ? "'$v'" : 'undef' }

my @PS = grep { -x $_ } map { "$_/ps" } split /:/, ($ENV{PATH} // '') . ':/bin:/usr/bin';
print "# perl $] on " . join(' ', (POSIX::uname())[0, 2, 4]) . '; ps ' . (@PS ? "present: $PS[0]" : 'absent') . "\n";
check(!@PS, 'the image has no ps (this case checks the /proc reading without it)');

# the libraries the helper's main.pl loads first, then the skills readers
for my $l (qw(util jsonc sha ctx spec settings paths roots log rc identity lock nonce)) { require "$l.pm" }
require skills::core;
require skills::ctx;
require skills::wait;

my $t0 = time();
my $kid = fork() // die "fork: $!";
if ($kid == 0) { $0 = 'r4 no-ps (kid)'; sleep 50; POSIX::_exit(0) }
my $t1 = time();
select(undef, undef, undef, 0.2);

check(identity->can(q(start_epoch)), q(identity::start_epoch exists (the uncached reader the wait helper uses)));
my $e = eval { identity::start_epoch($kid) };
my $s = identity::start_time($kid);
check(defined $e && $e >= $t0 - 2 && $e <= $t1 + 2, "start_epoch(kid) " . show($e) . " lies within the fork's second ($t0..$t1, +-2 s)");
check(defined $s && defined $e && (identity::lstart_epoch($s) // -1) == $e, "start_time(kid) " . show($s) . " is the same reading");
my $ls = skills::core::lstart($kid);
check(defined $ls && defined $s && $ls eq $s, "skills::core::lstart(kid) " . show($ls) . " equals start_time");

my $wrong = 'Mon Jan 1 00:00:00 2001';
check(skills::ctx::pid_state($kid, $s // '') eq 'match', 'skills::ctx::pid_state(kid, its start) is match');
my $ps = skills::ctx::pid_state($kid, $wrong);
check($ps eq 'gone', "skills::ctx::pid_state(kid, another start) is gone (got $ps; unverified = the start was not read)");
check(identity::alive($kid, $s) == 1, 'identity::alive(kid, its start) is 1');
check(identity::alive($kid, $wrong) == 0, 'identity::alive(kid, another start) is 0');

my $ctx = { notes => [] };
my $w1 = skills::wait::_pid_state({ pid => $kid, start => 1, given => 1 }, $ctx, 0);
check($w1 eq 'reused', "wait pid-exit:kid\@1 reads reused (got $w1)");
my $w2 = skills::wait::_pid_state({ pid => $kid, start => $e // 0, given => 1 }, $ctx, 0);
check($w2 eq 'alive', "wait pid-exit:kid\@<its start> reads alive (got $w2)");
my $u = { pid => $kid, given => 0 };
skills::wait::_pid_state($u, $ctx, 1);
check(defined $u->{start} && defined $e && $u->{start} == $e, 'wait pid-exit:kid (unanchored) anchors at its start ' . show($u->{start}));

kill 'KILL', $kid;
waitpid($kid, 0);
check(!defined eval { identity::start_epoch($kid) }, 'start_epoch of the ended kid is undef');
my $w3 = skills::wait::_pid_state({ pid => $kid, start => $e // 0, given => 1 }, $ctx, 0);
check($w3 eq 'gone', "wait pid-exit on the ended kid reads gone (got $w3)");

print "DONE checks=$checks fails=$fails\n";
exit($fails ? 1 : 0);

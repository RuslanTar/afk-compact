package lock;
# lib/lock.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# lock::with(path, owner, fn) -> owner = sid + actor + pid + lstart + host; stale only when the pid is dead or its start time differs -> lock_stale
sub with {
    my ($path, $owner, $fn) = @_;
    _not_implemented('with');
}

sub _not_implemented { die "lock::$_[0]: not implemented\n" }

1;

package queue;
# lib/queue.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# queue::call(argv, budget_ms)
sub call {
    my ($argv, $budget_ms) = @_;
    _not_implemented('call');
}

sub _not_implemented { die "queue::$_[0]: not implemented\n" }

1;

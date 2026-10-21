package roots;
# lib/roots.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# roots::check(settings) -> ok | refused(reason)
sub check {
    my ($settings) = @_;
    _not_implemented('check');
}

sub _not_implemented { die "roots::$_[0]: not implemented\n" }

1;

package paths;
# lib/paths.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# paths::for(settings, sid) -> {root, watch, disposable}
sub for {
    my ($settings, $sid) = @_;
    _not_implemented('for');
}

sub _not_implemented { die "paths::$_[0]: not implemented\n" }

1;

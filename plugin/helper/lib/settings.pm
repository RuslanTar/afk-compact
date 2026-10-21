package settings;
# lib/settings.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# settings::resolve(flags) -> Settings
sub resolve {
    my ($flags) = @_;
    _not_implemented('resolve');
}

sub _not_implemented { die "settings::$_[0]: not implemented\n" }

1;

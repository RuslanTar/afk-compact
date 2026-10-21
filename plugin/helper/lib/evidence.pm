package evidence;
# lib/evidence.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# evidence::copy(src, dest_dir, caps, index) -> row
sub copy {
    my ($src, $dest_dir, $caps, $index) = @_;
    _not_implemented('copy');
}

sub _not_implemented { die "evidence::$_[0]: not implemented\n" }

1;

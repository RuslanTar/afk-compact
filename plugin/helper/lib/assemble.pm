package assemble;
# lib/assemble.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# assemble::asset(name, tags, runtime) -> text
sub asset {
    my ($name, $tags, $runtime) = @_;
    _not_implemented('asset');
}

sub _not_implemented { die "assemble::$_[0]: not implemented\n" }

1;

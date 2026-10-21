package nonce;
# lib/nonce.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# nonce::draw(sid) -> nonce
sub draw {
    my ($sid) = @_;
    _not_implemented('draw');
}

sub _not_implemented { die "nonce::$_[0]: not implemented\n" }

1;

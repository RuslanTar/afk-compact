package frontmatter;
# lib/frontmatter.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# frontmatter::write(args) -> arguments not fixed by BUILD-PLAN §3.6; WP-core sets them
sub write {
    my @args = @_;
    _not_implemented('write');
}

# frontmatter::read(args) -> arguments not fixed by BUILD-PLAN §3.6; WP-core sets them
sub read {
    my @args = @_;
    _not_implemented('read');
}

sub _not_implemented { die "frontmatter::$_[0]: not implemented\n" }

1;

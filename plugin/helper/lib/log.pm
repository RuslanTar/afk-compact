package log;
# lib/log.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# log::append(stream, row)
sub append {
    my ($stream, $row) = @_;
    _not_implemented('append');
}

# log::row(ev, fields, ctx) -> row
sub row {
    my ($ev, $fields, $ctx) = @_;
    _not_implemented('row');
}

sub _not_implemented { die "log::$_[0]: not implemented\n" }

1;

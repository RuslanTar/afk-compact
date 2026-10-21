package secrets;
# lib/secrets.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# secrets::scan(text) -> [{rule, class}]
sub scan {
    my ($text) = @_;
    _not_implemented('scan');
}

# secrets::classify_file(path) -> copy | redact | withhold
sub classify_file {
    my ($path) = @_;
    _not_implemented('classify_file');
}

sub _not_implemented { die "secrets::$_[0]: not implemented\n" }

1;

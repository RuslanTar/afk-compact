package detect;
# lib/detect.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# detect::summary(text, dispatch) -> {verdict, marker_line, sentinel_from_end, nonce, scope, normalized, sha256}; $dispatch optional
sub summary {
    my ($text, $dispatch) = @_;
    _not_implemented('summary');
}

# detect::instructions(text, sid) -> {nonce, scope, has_record}
sub instructions {
    my ($text, $sid) = @_;
    _not_implemented('instructions');
}

sub _not_implemented { die "detect::$_[0]: not implemented\n" }

1;

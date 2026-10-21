package watch;
# lib/watch.pm: library seam of BUILD-PLAN §3.6. Owner: WP-watch.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# watch::on_hook(event, payload, ctx)
sub on_hook {
    my ($event, $payload, $ctx) = @_;
    _not_implemented('on_hook');
}

# watch::on_stop(ctx, deadline)
sub on_stop {
    my ($ctx, $deadline) = @_;
    _not_implemented('on_stop');
}

# watch::status_lines(sid) -> [line]
sub status_lines {
    my ($sid) = @_;
    _not_implemented('status_lines');
}

sub _not_implemented { die "watch::$_[0]: not implemented\n" }

1;

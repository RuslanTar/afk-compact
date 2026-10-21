package skills::measure_handoff;
# lib/skills/measure_handoff.pm: library seam of BUILD-PLAN §3.6. Owner: WP-skills.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# skills::measure_handoff::run(handoff, settings) -> lines of the `measure <handoff>` form (RDN); called by cmd/measure.pl (WP-core); argument list provisional (Phase 0)
sub run {
    my ($handoff, $settings) = @_;
    _not_implemented('run');
}

sub _not_implemented { die "skills::measure_handoff::$_[0]: not implemented\n" }

1;

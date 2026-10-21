package git;
# lib/git.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# git::measure(cwd, budget_ms)
sub measure {
    my ($cwd, $budget_ms) = @_;
    _not_implemented('measure');
}

sub _not_implemented { die "git::$_[0]: not implemented\n" }

1;

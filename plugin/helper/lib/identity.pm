package identity;
# lib/identity.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# identity::claude_pid() -> {pid, lstart}
sub claude_pid {
    _not_implemented('claude_pid');
}

sub _not_implemented { die "identity::$_[0]: not implemented\n" }

1;

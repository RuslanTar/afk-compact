package bucket;
# lib/bucket.pm: library seam of BUILD-PLAN §3.6. Owner: WP-core.
# Phase 0 stub: every call dies "not implemented" (main.pl turns an uncaught
# die into exit 70). The names and argument lists below are the seam.
use strict;
use warnings;

# bucket::resolve(sid, cwd, topic) -> {path, source}; $topic optional
sub resolve {
    my ($sid, $cwd, $topic) = @_;
    _not_implemented('resolve');
}

sub _not_implemented { die "bucket::$_[0]: not implemented\n" }

1;

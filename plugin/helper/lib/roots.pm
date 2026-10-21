package roots;
# lib/roots.pm: unsafe roots (MOD-SPEC §1.2 refined by D-12, provisional).
#   inside a .planning/ directory      -> REFUSED: root-in-planning
#   inside a git work tree, not ignored -> REFUSED: root-in-git
#   inside a work tree but git-ignored  -> ok, one root_in_git {key, ignored:true} row
# Owner: WP-core. The work-tree test walks up for `.git` (no git process); only
# the ignore test runs `git check-ignore`, and only behind the macOS git guard.
use strict;
use warnings;

my %CACHE;

sub _worktree_of {
    my ($path) = @_;
    my $p = util::real_path($path);
    while (defined $p && $p ne '' ) {
        return $p if -e "$p/.git";
        last if $p eq '/';
        $p = util::dirname($p);
    }
    return undef;
}

# check_path(path) -> {ok => 1} | {ok => 0, reason => ...} plus ignored => 1
sub check_path {
    my ($path) = @_;
    return { ok => 0, reason => 'root-unset' } unless defined $path && $path ne '';
    return $CACHE{$path} if $CACHE{$path};
    my $clean = util::clean_path($path);
    my $real = util::real_path($clean) // $clean;
    my $r;
    if (grep { $_ eq '.planning' } split m{/}, $real) {
        $r = { ok => 0, reason => 'root-in-planning' };
    } elsif (my $wt = _worktree_of($real)) {
        my $ignored = git::check_ignore($wt, $real);
        $r = (defined $ignored && $ignored) ? { ok => 1, ignored => 1, worktree => $wt }
                                            : { ok => 0, reason => 'root-in-git' };
    } else {
        $r = { ok => 1 };
    }
    $CACHE{$path} = $r;
    return $r;
}

# check(settings) -> {handoff_root => r, log_dir => r, disposable_root => r} for the
# effective paths (log_dir = the effective watch dir).
sub check {
    my ($settings) = @_;
    my $p = paths::for($settings);
    return {
        handoff_root    => check_path($p->{root}),
        log_dir         => check_path($p->{watch}),
        disposable_root => check_path($p->{disposable}),
    };
}

1;

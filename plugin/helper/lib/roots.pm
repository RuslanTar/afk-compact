package roots;
# lib/roots.pm: unsafe roots (MOD-SPEC §1.2 Block A, D-12). Owner: WP-core.
# Private store (handoff_root, log_dir, disposable_root), in both handoff-root modes:
#   inside a .planning/ directory      -> REFUSED: root-in-planning
#   inside a git work tree, not ignored -> REFUSED: root-in-git
#   inside a work tree but git-ignored  -> ok, one root_in_git {key, ignored:true} row
# On a refusal no copy or evidence is written under that root; compaction shaping still
# runs. The work-tree test walks up for `.git` (no git process); only the ignore test
# runs `git check-ignore`, and only behind the macOS git guard.
# Repository root (<toplevel>/<decl.root>, MOD-SPEC §1.5.3): meant to be tracked, so
# root-in-git does not apply; repo_check() checks it instead (lstat walk from the
# toplevel, then `git check-ignore` for the ignored note). A root that fails drops the
# call to private mode (lib/repomode.pm) and never leads to a write under the repository.
use strict;
use warnings;

my %CACHE;
# A hook sets one deadline (epoch ms) for all its root checks, so `git check-ignore`
# cannot eat its timeout. A check that runs out of time is `root-unchecked`: writes under
# that root are skipped for this call, and an ignored root is never reported as root-in-git.
our $DEADLINE;

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
    # letter case ignored: on a case-insensitive file system (macOS default) .Planning is .planning
    if (grep { lc($_) eq '.planning' } split m{/}, $real) {
        $r = { ok => 0, reason => 'root-in-planning' };
    } elsif (my $wt = _worktree_of($real)) {
        my $t = defined $DEADLINE ? $DEADLINE - util::clock_ms() : 2000;
        $t = 2000 if $t > 2000;
        my $ignored = $t >= 50 ? git::check_ignore($wt, $real, $t) : -1;
        $r = !defined $ignored ? { ok => 0, reason => 'root-in-git' }
           : $ignored == -1    ? { ok => 0, reason => 'root-unchecked' }
           : $ignored          ? { ok => 1, ignored => 1, worktree => $wt }
           :                     { ok => 0, reason => 'root-in-git' };
    } else {
        $r = { ok => 1 };
    }
    $CACHE{$path} = $r;
    return $r;
}

# repo_check(toplevel, root) -> {ok => 1, path, ignored => 0|1} | {ok => 0, reason} (D-12
# §1.5.3). `root` is the declaration's relative path. Checks, in order: the resolved path
# lies inside realpath(toplevel) (repo-root-escape); no existing component from the
# toplevel down is a symlink (repo-root-symlink); none is .git or inside it
# (repo-root-in-git-dir); none is .planning (repo-root-in-planning); no .git file or
# folder between the toplevel and the root, i.e. a nested repository or submodule
# (repo-root-nested). Then the ignore test (git check-ignore, the hook deadline applies:
# repo-root-unchecked when it runs out; repo-git-unavailable without git).
sub repo_check {
    my ($top, $root) = @_;
    return { ok => 0, reason => 'repo-root-escape' } unless defined $top && $top ne '' && defined $root && $root ne '';
    my $rtop = util::real_path($top) // return { ok => 0, reason => 'repo-root-escape' };
    return { ok => 0, reason => 'repo-root-escape' } if $root =~ m{^/};
    my @parts = grep { $_ ne '' && $_ ne '.' } split m{/+}, $root;
    return { ok => 0, reason => 'repo-root-escape' } if !@parts || grep { $_ eq '..' } @parts;
    my $p = $rtop;
    for my $i (0 .. $#parts) {
        my $c = $parts[$i];
        # letter case ignored (CR-F1): on a case-insensitive file system .GIT is the .git folder
        return { ok => 0, reason => 'repo-root-in-git-dir' } if $c =~ /^\.git/i;
        return { ok => 0, reason => 'repo-root-in-planning' } if lc($c) eq '.planning';
        $p .= "/$c";
        next unless -e $p || -l $p;
        return { ok => 0, reason => 'repo-root-symlink' } if -l $p;
        my $real = util::real_path($p) // $p;
        return { ok => 0, reason => 'repo-root-escape' } unless index("$real/", "$rtop/") == 0;
        # a nested repository or submodule: a .git entry in any folder below the toplevel
        return { ok => 0, reason => 'repo-root-nested' } if -d $p && (-e "$p/.git" || -l "$p/.git");
    }
    my $t = defined $DEADLINE ? $DEADLINE - util::clock_ms() : 2000;
    $t = 2000 if $t > 2000;
    return { ok => 0, reason => 'repo-root-unchecked' } if $t < 50;
    # the trailing slash says "a folder", so a dir pattern (`handoffs/`) matches a root not made yet
    my $ign = git::check_ignore($rtop, "$p/", $t);
    return { ok => 0, reason => 'repo-root-unchecked' } if defined $ign && $ign == -1;
    return { ok => 0, reason => 'repo-git-unavailable' } if !defined $ign && !git::available();
    return { ok => 1, path => $p, ignored => ($ign ? 1 : 0) };
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

package skills::gitfacts;
# lib/skills/gitfacts.pm: git facts for begin, publish, measure <handoff> and
# locate. Each call is bounded (2 s); on macOS git runs only when the
# Command Line Tools are present (R-4: /usr/bin/git is a stub without them).
use strict;
use warnings;
use File::Basename ();
use skills::util;

my $USABLE;
sub usable {
    return $USABLE if defined $USABLE;
    my $git = skills::util::which('git');
    if (!$git) { return $USABLE = 0 }
    if ($^O eq 'darwin' && $git eq '/usr/bin/git') {
        my $r = skills::util::run(['xcode-select', '-p'], 2000);
        return $USABLE = ($r->{rc} == 0 ? 1 : 0);
    }
    return $USABLE = 1;
}

# git -C <cwd> args… → {rc, out, timed_out}
sub git {
    my ($cwd, @args) = @_;
    return { rc => -1, out => '', timed_out => 0 } unless usable();
    return skills::util::run(['git', '-C', $cwd, @args], 2000, trace => 'git');
}

sub line { my ($r) = @_; return undef if $r->{rc} != 0; my $v = $r->{out}; $v =~ s/\s+\z//; return $v eq '' ? undef : $v }

# Repo identity for a directory. {in_git, repo, worktree, common_dir}
sub where {
    my ($cwd) = @_;
    my $top = line(git($cwd, 'rev-parse', '--show-toplevel'));
    if (!defined $top) {
        my $b = File::Basename::basename(skills::util::abs_path($cwd) // $cwd);
        return { in_git => 0, repo => $b, worktree => undef };
    }
    my $common = line(git($cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'));
    if (!defined $common) {
        $common = line(git($cwd, 'rev-parse', '--git-common-dir')) // '.git';
        $common = "$top/$common" unless $common =~ m{\A/};
    }
    $common = skills::util::abs_path($common) // $common;
    my $repo = File::Basename::basename(File::Basename::dirname($common));
    return { in_git => 1, repo => $repo, worktree => $top, common_dir => $common };
}

# Full working-state facts (HDN §6 begin; RDN measure).
sub facts {
    my ($cwd) = @_;
    my $w = where($cwd);
    return $w unless $w->{in_git};
    my $top = $w->{worktree};
    $w->{branch} = line(git($top, 'rev-parse', '--abbrev-ref', 'HEAD'));
    $w->{head} = line(git($top, 'rev-parse', '--short', 'HEAD'));
    $w->{head_full} = line(git($top, 'rev-parse', 'HEAD'));
    my $st = git($top, 'status', '--porcelain');
    my @lines = $st->{rc} == 0 ? grep { $_ ne '' } split /\n/, $st->{out} : ();
    $w->{porcelain_measured} = $st->{rc} == 0 ? 1 : 0;
    $w->{porcelain} = [ @lines[0 .. ($#lines < 19 ? $#lines : 19)] ];
    $w->{dirty_count} = scalar @lines;
    my $ab = line(git($top, 'rev-list', '--left-right', '--count', '@{upstream}...HEAD'));
    if (defined $ab && $ab =~ /\A(\d+)\s+(\d+)\z/) { @$w{qw(behind ahead)} = (0 + $1, 0 + $2) }
    else { @$w{qw(behind ahead)} = (undef, undef) }
    my $gd = line(git($top, 'rev-parse', '--path-format=absolute', '--git-dir')) // "$top/.git";
    my @prog;
    push @prog, 'merge' if -e "$gd/MERGE_HEAD";
    push @prog, 'rebase' if -d "$gd/rebase-merge" || -d "$gd/rebase-apply";
    push @prog, 'cherry-pick' if -e "$gd/CHERRY_PICK_HEAD";
    push @prog, 'revert' if -e "$gd/REVERT_HEAD";
    $w->{in_progress} = \@prog;
    return $w;
}

# RV-18: hash of `git diff HEAD` content plus untracked file hashes, so an
# edit to an already-dirty file changes it.
sub work_hash {
    my ($top) = @_;
    return undef unless defined $top;
    my $d = git($top, 'diff', 'HEAD', '--binary');
    return undef if $d->{rc} != 0;
    my $acc = 'diff:' . skills::util::sha256_hex($d->{out}) . "\n";
    my $u = git($top, 'ls-files', '--others', '--exclude-standard', '-z');
    return undef if $u->{rc} != 0;
    for my $f (sort grep { $_ ne '' } split /\0/, $u->{out}) {
        my $p = "$top/$f";
        my $h = (-f $p && -s _ <= 10 * 1024 * 1024) ? (skills::util::sha256_file($p) // 'unreadable') : ('size:' . (-s $p // 0));
        $acc .= "$f\t$h\n";
    }
    return skills::util::sha256_hex($acc);
}

# A revision read from a file (frontmatter git_commit) must be a commit id,
# never an option: `--output=<path>..HEAD` would make git write a file.
sub rev_ok { my ($r) = @_; return (defined $r && $r =~ /\A(?:[0-9a-fA-F]{7,64}|HEAD)\z/) ? 1 : 0 }

# Commits in <base>..HEAD: [{hash, short, author, ctime}]
sub commits_since {
    my ($top, $base, $max) = @_;
    $max //= 200;
    return undef unless rev_ok($base);
    my $r = git($top, 'log', "--max-count=$max", '--format=%H%x09%h%x09%an%x09%ct', "$base..HEAD");
    return undef if $r->{rc} != 0;
    my @c;
    for my $l (split /\n/, $r->{out}) {
        my ($h, $s, $a, $t) = split /\t/, $l;
        push @c, { hash => $h, short => $s, author => $a, ctime => $t } if $h;
    }
    return \@c;
}

sub is_ancestor {
    my ($top, $a, $b) = @_;
    return 0 unless rev_ok($a) && rev_ok($b);
    my $r = git($top, 'merge-base', '--is-ancestor', $a, $b);
    return $r->{rc} == 0 ? 1 : 0;
}

sub check_ignore {
    my ($top, $path) = @_;
    return undef unless defined $top;
    my $r = git($top, 'check-ignore', '-q', '--', $path);
    return $r->{rc} == 0 ? 1 : ($r->{rc} == 1 ? 0 : undef);
}

sub worktrees {
    my ($top) = @_;
    my $r = git($top, 'worktree', 'list', '--porcelain');
    return [] if $r->{rc} != 0;
    return [ map { /\Aworktree (.+)\z/ ? $1 : () } split /\n/, $r->{out} ];
}

sub ticket { my ($s) = @_; return (defined $s && $s =~ /([A-Z][A-Z0-9]+-[0-9]+)/) ? $1 : undef }

1;

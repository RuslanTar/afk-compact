package git;
# lib/git.pm: read-only git facts with budgets (MOD-SPEC §7, §10). Owner: WP-core.
# macOS guard (R-4): when `git` resolves to /usr/bin/git (a CLT stub on a Mac
# without the Command Line Tools), `xcode-select -p` must exit 0 first; otherwise
# no git process starts and git facts read `unavailable`.
use strict;
use warnings;
use utf8;

my $AVAIL;
my $BIN;

sub available {
    return $AVAIL if defined $AVAIL;
    $BIN = util::which('git');
    if (!$BIN) { $AVAIL = 0; return 0 }
    if ($^O eq 'darwin') {
        my $real = util::real_path($BIN) // $BIN;
        if ($BIN eq '/usr/bin/git' || $real eq '/usr/bin/git') {
            my $xs = util::which('xcode-select') // (-x '/usr/bin/xcode-select' ? '/usr/bin/xcode-select' : undef);
            my $r = $xs ? util::run([$xs, '-p'], timeout_ms => 2000) : { exit => 1 };
            if ($r->{exit} != 0) { $AVAIL = 0; return 0 }
        }
    }
    $AVAIL = 1;
    return 1;
}

# run git with a timeout; -> run result, or {exit => -2, unavailable => 1}
sub cmd {
    my ($cwd, $args, $timeout_ms) = @_;
    return { exit => -2, out => '', unavailable => 1, ms => 0 } unless available();
    util::trace('git');
    # `out` is the bytes git printed: paths (toplevel, git dir) stay bytes (SR 1.1); the text
    # parts (branch, status lines) are decoded once where they are read (MOD-SPEC §2.6)
    return util::run([$BIN, "-C", util::fsb($cwd), @$args], timeout_ms => $timeout_ms // 2000,
                     env => { GIT_OPTIONAL_LOCKS => "0", LC_ALL => "C", GIT_TERMINAL_PROMPT => "0" });
}

# 1 ignored, 0 not ignored, -1 timed out, undef unknown (no git / error)
sub check_ignore {
    my ($wt, $path, $timeout_ms) = @_;
    my $r = cmd($wt, ['check-ignore', '-q', '--no-index', $path], $timeout_ms // 2000);
    return -1 if $r->{timed_out};
    return undef if $r->{unavailable};
    return 1 if $r->{exit} == 0;
    return 0 if $r->{exit} == 1;
    return undef;
}

# where(cwd) -> {in_git, toplevel, common_dir, repo, branch, head} with one or two calls
sub where {
    my ($cwd, $timeout_ms) = @_;
    my $res = { in_git => 0, repo => (defined $cwd ? util::basename($cwd) : undef) };
    return { %$res, unavailable => 1 } unless available();
    return $res unless defined $cwd && -d $cwd;
    my $r = cmd($cwd, ['rev-parse', '--path-format=absolute', '--git-common-dir', '--show-toplevel', 'HEAD'], $timeout_ms // 2000);
    if ($r->{timed_out}) { return { %$res, timeout => 1 } }
    my @l = split /\n/, $r->{out};
    if ($r->{exit} != 0 && @l < 2) {
        my $r2 = cmd($cwd, ['rev-parse', '--git-common-dir', '--show-toplevel'], $timeout_ms // 2000);
        return $res unless $r2->{exit} == 0;
        @l = split /\n/, $r2->{out};
        $l[0] = util::clean_path($l[0], $cwd) if @l;
    }
    return $res unless @l >= 2;
    $res->{in_git} = 1;
    $res->{common_dir} = $l[0];
    $res->{toplevel} = $l[1];
    $res->{head} = (defined $l[2] && $l[2] =~ /^[0-9a-f]{7,64}$/) ? $l[2] : undef;
    my $cd = $l[0];
    $cd =~ s{/+$}{};
    $res->{repo} = util::basename(util::dirname($cd));
    my $b = cmd($cwd, ['symbolic-ref', '--short', '-q', 'HEAD'], $timeout_ms // 2000);
    ($res->{branch} = util::text($b->{out})) =~ s/\s+$// if $b->{exit} == 0;
    return $res;
}

# measure(cwd, budget_ms) -> {status: ok|timeout|unavailable|not-git, branch, head,
#   porcelain => [first 20], count, ahead, behind, ms, op, toplevel}
sub measure {
    my ($cwd, $budget_ms) = @_;
    my $t0 = util::clock_ms();
    my $deadline = $t0 + ($budget_ms // 2000);
    my $left = sub { my $l = $deadline - util::clock_ms(); return $l < 50 ? 50 : $l };
    return { status => 'unavailable', ms => 0 } unless available();
    return { status => 'not-git', ms => 0 } unless defined $cwd && -d $cwd;
    my $r = cmd($cwd, ['status', '--porcelain=v1', '--branch', '--untracked-files=normal'], $left->());
    my $ms = sub { util::clock_ms() - $t0 };
    return { status => 'timeout', ms => $ms->() } if $r->{timed_out} || util::clock_ms() >= $deadline;
    return { status => 'not-git', ms => $ms->() } if $r->{exit} != 0;
    my @lines = split /\n/, util::text($r->{out});    # status lines and the branch are text
    my $head_line = (@lines && $lines[0] =~ /^## /) ? shift @lines : '';
    my ($branch, $ahead, $behind) = (undef, 0, 0);
    if ($head_line =~ /^## (.*)$/) {
        my $rest = $1;
        my $tr = ($rest =~ s/ \[([^\]]*)\]$//) ? $1 : '';
        $rest =~ s/^No commits yet on //;
        ($branch) = split /\.\.\./, $rest, 2;
        ($ahead) = $tr =~ /ahead (\d+)/;
        ($behind) = $tr =~ /behind (\d+)/;
    }
    $branch = undef if defined $branch && $branch =~ /^HEAD/;
    my $h = cmd($cwd, ['rev-parse', '--short=12', 'HEAD'], $left->());
    return { status => 'timeout', ms => $ms->() } if $h->{timed_out};
    my $head = $h->{exit} == 0 ? ($h->{out} =~ /^(\S+)/)[0] : undef;
    # one call for the git dir and the work-tree top, so a caller needs no second git::where
    my $gd = cmd($cwd, ['rev-parse', '--absolute-git-dir', '--show-toplevel'], $left->());
    my ($op, $top);
    if ($gd->{exit} == 0) {
        my ($d, $t) = split /\n/, $gd->{out};
        if (defined $d && $d =~ /\S/) {
            $op = 'merge' if -e "$d/MERGE_HEAD";
            $op = 'rebase' if -d "$d/rebase-merge" || -d "$d/rebase-apply";
        }
        $top = $t if defined $t && $t =~ m{^/};
    }
    my $count = scalar @lines;
    return { status => 'ok', branch => $branch, head => $head, porcelain => [@lines[0 .. ($count > 20 ? 19 : $count - 1)]],
             count => $count, ahead => 0 + ($ahead // 0), behind => 0 + ($behind // 0), op => $op, toplevel => $top, ms => $ms->() };
}

1;

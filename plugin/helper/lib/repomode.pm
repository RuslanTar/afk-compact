package repomode;
# lib/repomode.pm: the handoff-root mode of one worktree.
# Decided per worktree and per helper call, cached for the call:
#   repo     the worktree's <toplevel>/.claude/handoffs.json is valid, the
#            user's repo_roots accepts this repository (settings file only; an
#            entry names its toplevel, or its main checkout when git made this
#            worktree for that clone, linked_worktree) and
#            roots::repo_check passes. Everything still goes to the private
#            store; publish adds a portable export under <toplevel>/<decl.root>.
#   private  every other case, with mode_reason not-declared | not-accepted |
#            repo-decl-invalid | repo-root-escape | repo-root-symlink | repo-root-in-git-dir
#            | repo-root-in-planning | repo-root-nested | repo-git-unavailable |
#            repo-root-unchecked (timed out)
# The declaration only says where exports go; it cannot change what is exported or
# anything in the private store. Nothing here writes under the repository: the
# declaration, README and .gitignore are written by `project init`, the
# exports by `publish`. Rows (once per session, rc once-markers): handoff_mode {mode,
# reason, declared, accepted}, repo_root_ignored, repo_gitignore_drift, decl_unknown_keys.
use strict;
use warnings;
use utf8;

our $DECL = '.claude/handoffs.json';
our $DECL_MAX = 4096;
our $DEFAULT_ROOT = '.claude/handoffs';
our %DECL_KEYS = map { $_ => 1 } qw(version mode root);

# The generated <decl.root>/.gitignore: written once by `project init`, never
# rewritten or merged into; an existing one that lacks a line is `repo_gitignore_drift`.
our @GITIGNORE_LINES = ('.staging/', 'compact/', 'evidence/', '*.tmp-*', '*.lock');
sub gitignore_text {
    return join("\n", '# Written once by the handoff plugin. Only published handoff exports belong in this folder.',
                @GITIGNORE_LINES) . "\n";
}

my %CACHE;

# declaration(toplevel) -> {present => 0} | {present => 1, valid => 0|1, root, why, unknown => [keys]}
sub declaration {
    my ($top) = @_;
    my $f = "$top/$DECL";
    return { present => 0 } unless -e $f || -l $f;
    return { present => 1, valid => 0, why => 'not-a-file' } if -l $f || !-f $f;
    my $size = -s $f;
    return { present => 1, valid => 0, why => 'too-large' } if !defined $size || $size > $DECL_MAX;
    my $raw = util::read_file($f, $DECL_MAX) // return { present => 1, valid => 0, why => 'unreadable' };
    my $j = eval { jsonc::decode($raw) };
    return { present => 1, valid => 0, why => 'not-json' } unless ref $j eq 'HASH';
    my @unknown = sort grep { !$DECL_KEYS{$_} } keys %$j;
    my $bad = sub { return { present => 1, valid => 0, why => $_[0], unknown => \@unknown } };
    return $bad->('version') unless defined $j->{version} && !ref $j->{version} && "$j->{version}" eq '1';
    return $bad->('mode') unless defined $j->{mode} && !ref $j->{mode} && $j->{mode} eq 'repo';
    my $root = exists $j->{root} ? $j->{root} : $DEFAULT_ROOT;
    return $bad->('root') unless valid_root($root);
    return { present => 1, valid => 1, root => util::to_bytes($root), unknown => \@unknown };
}

# valid_root(rel) -> 1 for a relative path of 1 to 4 components, each [A-Za-z0-9._-]+,
# none `.` or `..`, none starting with `.git`, none `.planning`.
sub valid_root {
    my ($r) = @_;
    return 0 unless defined $r && !ref $r && $r ne '' && $r !~ m{^/} && $r !~ m{/$};
    my @c = split m{/}, $r, -1;
    return 0 if @c < 1 || @c > 4;
    for my $c (@c) {
        return 0 unless $c =~ /\A[A-Za-z0-9._-]+\z/;
        # letter case ignored: .GIT and .Planning are the same folders on a
        # case-insensitive file system
        return 0 if $c eq '.' || $c eq '..' || $c =~ /^\.git/i || lc($c) eq '.planning';
    }
    return 1;
}

# main_checkout(where) -> the parent of git-common-dir when that path ends in /.git
sub main_checkout {
    my ($w) = @_;
    my $cd = $w->{common_dir} // return undef;
    $cd =~ s{/+$}{};
    return undef unless $cd =~ m{/\.git$};
    return util::dirname($cd);
}

# dir_id(path) -> "dev:ino" of what path names, or undef. Two spellings of one folder on
# a case-insensitive file system have one id (CR-F5).
sub dir_id {
    my ($p) = @_;
    return undef unless defined $p && $p ne '';
    my @s = stat $p;
    return @s ? "$s[0]:$s[1]" : undef;
}

# same_dir(a, b) -> 1 when both name one existing folder (equal real path, or one dev:ino)
sub same_dir {
    my ($x, $y) = @_;
    return 0 unless defined $x && defined $y;
    return 1 if $x eq $y;
    my ($ix, $iy) = (dir_id($x), dir_id($y));
    return (defined $ix && defined $iy && $ix eq $iy) ? 1 : 0;
}

# linked_worktree(toplevel, common_dir) -> 1 when toplevel is a worktree git itself made
# for that common dir: <toplevel>/.git is a plain file
# `gitdir: <admin>`, <admin> sits in <common_dir>/worktrees/, and <admin>/gitdir names
# <toplevel>/.git back. A folder whose own .git file merely points at an accepted clone's
# git dir fails this, so it cannot borrow that clone's acceptance (nothing is
# written into a repository on the repository's word alone). Git for Windows writes both gitdir
# lines in drive form (C:/x): each is read in this platform's form (util::posix_form) before it is
# joined to its folder (sitting 4, P1).
sub linked_worktree {
    my ($top, $cd) = @_;
    return 0 unless defined $top && defined $cd;
    my $dotgit = "$top/.git";
    return 0 if -l $dotgit || !-f $dotgit;
    my $txt = util::read_file($dotgit, 4096) // return 0;
    return 0 unless $txt =~ /\Agitdir:[ \t]*([^\r\n]+?)[ \t]*\r?(?:\n|\z)/;
    my $adm = util::real_path(util::clean_path(util::posix_form($1), $top)) // return 0;
    return 0 unless -d $adm;
    return 0 unless same_dir(util::dirname($adm), util::clean_path("$cd/worktrees"));
    my $back = util::read_file("$adm/gitdir", 4096) // return 0;
    $back =~ s/\s+\z//;
    return 0 if $back eq '';
    my $rb = util::real_path(util::clean_path(util::posix_form($back), $adm)) // return 0;
    my $rd = util::real_path($dotgit) // return 0;
    return 1 if $rb eq $rd;
    # one file under two spellings (case-insensitive file system), not a hard link
    my @s = stat $dotgit;
    return (@s && $s[3] == 1 && same_dir($rb, $rd)) ? 1 : 0;
}

# gitignore_drift(dir) -> 1 when dir/.gitignore exists and lacks a generated line
sub gitignore_drift {
    my ($dir) = @_;
    my $f = "$dir/.gitignore";
    return 0 unless -f $f;
    my %have = map { my $l = $_; $l =~ s/\s+$//; ($l => 1) } split /\n/, (util::read_file($f, 65536) // '');
    return (grep { !$have{$_} } @GITIGNORE_LINES) ? 1 : 0;
}

# exports(dir) -> number of export files (*.md below the topic folders; the README at the
# top is not one), bounded: 6 levels, 20,000 entries read in all (the walk stops
# there; no folder is read past the bound).
our $EXPORTS_MAX = 20000;
sub exports {
    my ($dir) = @_;
    return 0 unless -d $dir && !-l $dir;
    my ($n, $seen) = (0, 0);
    my @stack = ([$dir, 0]);
    while ($seen < $EXPORTS_MAX && (my $e = pop @stack)) {
        my ($d, $depth) = @$e;
        my @x = util::list_dir_max($d, $EXPORTS_MAX - $seen);
        $seen += @x;
        for my $x (@x) {
            next if $x =~ /^\./;
            my $p = "$d/$x";
            next if -l $p;
            if (-d _) { push @stack, [$p, $depth + 1] if $depth < 6; next }
            $n++ if $depth >= 1 && $x =~ /\.md$/ && -f _;
        }
    }
    return $n;
}

# decide(cwd, %o) -> {mode, reason, declared, accepted, toplevel, main_checkout, decl,
#   root_rel, root_path, ignored, gitignore_drift, exports, store_inside, stale}
# o: settings => resolved settings (default rc::settings()), where => git::where result.
sub decide {
    my ($cwd, %o) = @_;
    $cwd = util::clean_path($cwd // do { require Cwd; Cwd::getcwd() });
    return $CACHE{$cwd} if $CACHE{$cwd} && !$o{fresh};
    my $s = $o{settings} // rc::settings();
    my %r = (mode => 'private', declared => 0, accepted => 0, ignored => 0, gitignore_drift => 0, exports => 0,
             store_inside => 0, stale => []);
    my $done = sub { my ($reason) = @_; $r{reason} = $reason; $CACHE{$cwd} = \%r; return \%r };
    my $t = defined $roots::DEADLINE ? $roots::DEADLINE - util::clock_ms() : 2000;
    $t = 2000 if $t > 2000;
    return $done->('repo-root-unchecked') if $t < 50;
    my $w = $o{where} // git::where($cwd, $t);
    return $done->('repo-git-unavailable') if $w->{unavailable};
    return $done->('repo-root-unchecked') if $w->{timeout};
    return $done->('not-declared') unless $w->{in_git} && defined $w->{toplevel};
    my $top = util::to_bytes($w->{toplevel});
    $r{toplevel} = $top;
    $r{main_checkout} = util::to_bytes(main_checkout($w));
    my $acc = settings::repo_roots($s);
    $r{stale} = $acc->{stale};
    # Entries match by real path or by folder identity (CR-F5: an entry that differs from
    # git's toplevel only in letter case names the same folder on macOS).
    my %ok = map { ($_ => 1) } @{ $acc->{roots} };
    my %okid = map { my $i = dir_id($_); defined $i ? ($i => 1) : () } @{ $acc->{roots} };
    my $listed = sub { my ($p) = @_; return 0 unless defined $p; return 1 if $ok{$p}; my $i = dir_id($p); return (defined $i && $okid{$i}) ? 1 : 0 };
    my $rtop = util::real_path($top) // $top;
    my $rmain = defined $r{main_checkout} ? (util::real_path($r{main_checkout}) // $r{main_checkout}) : undef;
    # The main checkout counts only for a worktree git made for it; otherwise this
    # toplevel is its own main checkout as far as acceptance goes.
    if (defined $rmain && !same_dir($rmain, $rtop) && !linked_worktree($top, $w->{common_dir})) {
        ($rmain, $r{main_checkout}) = (undef, undef);
    }
    $r{accepted} = ($listed->($rtop) || (defined $rmain && $listed->($rmain))) ? 1 : 0;
    my $root = rc::root();
    if (defined $root) {
        my $rr = util::real_path($root) // $root;
        $r{store_inside} = index("$rr/", "$rtop/") == 0 ? 1 : 0;
    }
    my $d = declaration($top);
    $r{decl} = $d;
    $r{declared} = $d->{present} ? 1 : 0;
    return $done->('not-declared') unless $d->{present};
    rc::emit('decl_unknown_keys', [keys => $d->{unknown}]) if @{ $d->{unknown} || [] } && rc::once('decl_unknown_keys');
    return $done->('repo-decl-invalid') unless $d->{valid};
    $r{root_rel} = $d->{root};
    $r{root_path} = "$top/$d->{root}";
    $r{exports} = exports($r{root_path});
    return $done->('not-accepted') unless $r{accepted};
    my $c = roots::repo_check($top, $d->{root});
    return $done->($c->{reason}) unless $c->{ok};
    $r{ignored} = $c->{ignored};
    $r{gitignore_drift} = gitignore_drift($r{root_path});
    rc::emit('repo_root_ignored', [root => $d->{root}]) if $r{ignored} && rc::once('repo_root_ignored');
    rc::emit('repo_gitignore_drift', [root => $d->{root}]) if $r{gitignore_drift} && rc::once('repo_gitignore_drift');
    $r{mode} = 'repo';
    return $done->('accepted');
}

1;

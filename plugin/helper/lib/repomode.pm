package repomode;
# lib/repomode.pm: the handoff-root mode of one worktree (MOD-SPEC §1.5, D-12). Owner:
# WP-core. Decided per worktree and per helper call, cached for the call:
#   repo     the worktree's <toplevel>/.claude/handoffs.json is valid (§1.5.2), the
#            user's repo_roots accepts this repository (§1.5.4, settings file only) and
#            roots::repo_check passes (§1.5.3). Everything still goes to the private
#            store; publish adds a portable export under <toplevel>/<decl.root>.
#   private  every other case, with mode_reason not-declared | not-accepted |
#            repo-decl-invalid | repo-root-escape | repo-root-symlink | repo-root-in-git-dir
#            | repo-root-in-planning | repo-root-nested | repo-git-unavailable |
#            repo-root-unchecked (timed out)
# The declaration only says where exports go; it cannot change what is exported or
# anything in the private store. Nothing here writes under the repository: the
# declaration, README and .gitignore are written by `project init` (WP-skills), the
# exports by `publish`. Rows (once per session, rc once-markers): handoff_mode {mode,
# reason, declared, accepted}, repo_root_ignored, repo_gitignore_drift, decl_unknown_keys.
use strict;
use warnings;

our $DECL = '.claude/handoffs.json';
our $DECL_MAX = 4096;
our $DEFAULT_ROOT = '.claude/handoffs';
our %DECL_KEYS = map { $_ => 1 } qw(version mode root);

# The generated <decl.root>/.gitignore (§1.5.6): written once by `project init`, never
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
# none `.` or `..`, none starting with `.git`, none `.planning` (§1.5.2).
sub valid_root {
    my ($r) = @_;
    return 0 unless defined $r && !ref $r && $r ne '' && $r !~ m{^/} && $r !~ m{/$};
    my @c = split m{/}, $r, -1;
    return 0 if @c < 1 || @c > 4;
    for my $c (@c) {
        return 0 unless $c =~ /\A[A-Za-z0-9._-]+\z/;
        return 0 if $c eq '.' || $c eq '..' || $c =~ /^\.git/ || $c eq '.planning';
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

# gitignore_drift(dir) -> 1 when dir/.gitignore exists and lacks a generated line
sub gitignore_drift {
    my ($dir) = @_;
    my $f = "$dir/.gitignore";
    return 0 unless -f $f;
    my %have = map { my $l = $_; $l =~ s/\s+$//; ($l => 1) } split /\n/, (util::read_file($f, 65536) // '');
    return (grep { !$have{$_} } @GITIGNORE_LINES) ? 1 : 0;
}

# exports(dir) -> number of export files (*.md below the topic folders; the README at the
# top is not one), bounded: 6 levels, 20,000 entries.
sub exports {
    my ($dir) = @_;
    return 0 unless -d $dir && !-l $dir;
    my ($n, $seen) = (0, 0);
    my @stack = ([$dir, 0]);
    while (my $e = pop @stack) {
        my ($d, $depth) = @$e;
        for my $x (util::list_dir($d)) {
            last if ++$seen > 20000;
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
    my %ok = map { ($_ => 1) } @{ $acc->{roots} };
    my $rtop = util::real_path($top) // $top;
    my $rmain = defined $r{main_checkout} ? (util::real_path($r{main_checkout}) // $r{main_checkout}) : undef;
    $r{accepted} = ($ok{$rtop} || (defined $rmain && $ok{$rmain})) ? 1 : 0;
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

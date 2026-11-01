package homeguard;
# tests/helper/homeguard.pm: HOME-GUARD (0.1.2), the one guard of every test runner here that
# starts children: the helper case runner (tests/helper/run.pl) and the watch driver
# (tests/helper/cases/watch/_driver/run-watch.pl, its T.pm). A kit test elsewhere ran a planted hook
# with the real HOME and wiped ~/.claude/settings.json to "{}"; lib/settings_write.pm writes
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json, and the helper writes its handoff root and
# watch logs under $XDG_STATE_HOME (else ~/.local/state), CLAUDE_PLUGIN_DATA and the
# CLAUDE_PLUGIN_OPTION_* folders. The guard refuses to start a child whose environment leads into
# the owner's real HOME, Claude Code config folder or state folders through what a child writes by:
# HOME, CLAUDE_CONFIG_DIR, the folders of PATH_VARS, the XDG defaults under HOME, and every symbolic
# link under those folders (a bounded walk; see check). A path a child is given in its arguments or
# stdin is the case's to choose and is not read here. Hard links are out of scope: one is made only
# by a process that already reaches the file by its path (which check refuses a child), cases make
# them on purpose among their own files (AT-SW-02), and matching every file under a temp HOME
# against every file of the real config and state folders would read the whole real ~/.claude.
#
# A runner calls init() once, before it changes its environment or writes anything (the real
# HOME, the account's home, the CLAUDE_CONFIG_DIR and the state folders given are read there, and
# a TMPDIR that is relative, has a `..` part, lies at or under a real config or state folder or
# lies at or above a real home dies there), then drops the caller's Claude Code, XDG, helper, git
# and shell start-up variables (drop_env) or starts from a fresh environment (fresh_env),
# add_temp_root() for a temp folder of its own outside the system one (which dies the same way),
# then check(env, what) before each child it starts. Needs core's util.pm (plugin/helper/lib)
# loaded. Paths are compared by real path (every link followed, a dangling one too: _real) and by
# device and inode (a case-insensitive file system reads /users/me as /Users/me, which a text
# compare misses).
use strict;
use warnings;

# the real folders, as init() read them (real_set): home (HOME as given), account (getpwuid's
# home), config_dir (the CLAUDE_CONFIG_DIR given), given (the PATH_VARS values given but
# XDG_RUNTIME_DIR and CLAUDE_CODE_TMPDIR), and by real path => "dev:ino" ('' while missing): homes
# (the real HOME and the account's home), configs (each real home's .claude and the
# CLAUDE_CONFIG_DIR given), states (each real home's .local, .cache and .config, and every
# absolute value given). A self-test stands in its own:
# `local %homeguard::REAL = homeguard::real_set(home => ..., ...)`, so no link into the real home
# or config folder is ever made.
our %REAL;
our $START_TMPDIR;
# the temp folders a child's HOME, CLAUDE_CONFIG_DIR and PATH_VARS values (and the folders under
# HOME in HOME_DIRS) may lie under: the system temp folder as given at start, /tmp, and each added
# one (real paths, filled on first use; a self-test may `local` it)
our (@EXTRA_TEMP, @TEMP_ROOTS);
# the folders a HOME given (never the account's home) may lie under and still be a throwaway one,
# which a temp root may hold (holds_home, throwaway): /tmp, a temp folder whatever TMPDIR is
# (tests/launcher/in-docker.sh runs with HOME and TMPDIR /tmp/t), and the core runner's repo tmp/
# (run.pl adds it with add_throwaway: a child run of a case under it gets that case's HOME as its
# real one, and adds that tmp/ as a temp root); holds_home reads the system temp folder as given
# at start as one too (on macOS a HOME made with `mktemp -d` lies under TMPDIR)
our @THROWAWAY = ('/tmp');
# the folders a child writes besides HOME and CLAUDE_CONFIG_DIR, as variables: the XDG base
# folders (the helper's default handoff root reads $XDG_STATE_HOME, the launcher's cache
# $XDG_CACHE_HOME), the plugin's data folder (hook.pl's last-version), its folder options, and
# Claude Code's temp folder
our @PATH_VARS = qw(XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR
                    CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT CLAUDE_PLUGIN_OPTION_LOG_DIR
                    CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT CLAUDE_CODE_TMPDIR);
# the folders a child writes under HOME when the XDG variables are unset: the XDG defaults
# (~/.local/state holds the helper's default handoff root and watch logs, ~/.cache the launcher's
# cache) and their parent ~/.local
our @HOME_DIRS = qw(.local .local/state .local/share .cache .config);
# the link walk's budget per check (see check): entries read in all, and folders down from a
# walked folder; past either the child is refused, never let through unread (a self-test may
# `local` them)
our ($WALK_MAX, $WALK_DEPTH) = (20000, 64);
# drop_env drops these names: Claude Code's (CLAUDECODE, CLAUDE_CONFIG_DIR, CLAUDE_PLUGIN_*,
# CLAUDE_CODE_*, ...), the XDG ones, the helper's own (STORE_*), git's (GIT_DIR,
# GIT_WORK_TREE, GIT_INDEX_FILE, GIT_CONFIG*, ...: git exports GIT_DIR to its hooks, and a runner
# started from one would put the fixture repos' commits and index into the owner's repo) and the
# shell start-up files a caller names (BASH_ENV, ENV, ZDOTDIR: a shell a case starts reads them;
# the launcher's run.sh and the watch driver's fresh environment drop them too)
our $DROP_RE = qr/\A(?:CLAUDE|XDG_|STORE_|GIT_|BASH_ENV\z|ENV\z|ZDOTDIR\z)/;
# fresh_env keeps only these from the caller's environment
our $KEEP_RE = qr/\A(?:PATH|TMPDIR|TZDIR|LANG|LANGUAGE|LC_[A-Z_]+|USER|LOGNAME|SHELL|TERM|PERL5LIB|PERLLIB)\z/;
my $INIT;

sub init {
    return if $INIT++;
    $START_TMPDIR = $ENV{TMPDIR};
    # the state folders given (not the runtime and temp ones, XDG_RUNTIME_DIR and
    # CLAUDE_CODE_TMPDIR: TMPDIR may lie under them)
    %REAL = real_set(home => $ENV{HOME}, account => (getpwuid($<))[7], config_dir => $ENV{CLAUDE_CONFIG_DIR},
                     given => { map { ($_ => $ENV{$_}) } grep { defined $ENV{$_} && !/\A(?:XDG_RUNTIME_DIR|CLAUDE_CODE_TMPDIR)\z/ } @PATH_VARS });
    # the runners make their run folders under TMPDIR before any child is checked
    check_temp_root($START_TMPDIR, 'TMPDIR') if defined $START_TMPDIR && $START_TMPDIR ne '';
    return;
}

# check_temp_root(path, what): dies before a runner writes there when a temp folder it makes its
# run folders under (TMPDIR at start, an added root) is relative (it would be read against
# whatever folder the runner is in), has a `..` part (the kernel applies it after links, util's
# real_path folds it as text first: with TMPDIR=$T/L/.. and L a link into ~/.claude, a run staged
# its plugin and case folders in ~/.claude), is at or under a real config or state folder (with
# TMPDIR=~/.claude the same happened before the first child was refused) or holds a real home (see
# holds_home: under_temp would read the whole home as temp, so a link to ~/.claude.json or
# ~/.gitconfig passed).
sub check_temp_root {
    my ($p, $what) = @_;
    return 1 unless defined $p;
    die "HOME-GUARD: $what $p is not absolute (it is read against the runner's folder); nothing written\n" unless $p =~ m{\A/};
    die "HOME-GUARD: $what $p has a .. part (applied after links); nothing written\n" if dotdot($p);
    die "HOME-GUARD: $what $p is in a real config folder; nothing written\n" if real_config($p);
    die "HOME-GUARD: $what $p is in a real state folder; nothing written\n" if real_state($p);
    # 0.1.3: the file system root holds every home, the account's or not, known or not, and
    # every path would read as under it (a TMPDIR of / or a link to it)
    if ((_real($p) // '') =~ m{\A/+\z}) {
        die "HOME-GUARD: $what $p is at or above the real home (it is the file system root: every file in it would read as temp); nothing written\n";
    }
    if (defined(my $h = holds_home($p))) {
        die "HOME-GUARD: $what $p is at or above the real home $h (every file in it would read as temp); nothing written\n";
    }
    return 1;
}

# holds_home(path) -> the real home (as its real path) that the path's real path is or holds (by
# text or by device and inode: a parent of the home that is the path), undef for none. A HOME
# given that is not the account's home (by real path or device and inode) and lies strictly under
# a THROWAWAY folder or the system temp folder as given at start is skipped: it is a temp folder
# already (a runner started by another one gets a temp HOME as its real one; on a host with no
# TMPDIR its child runs take TMPDIR=/tmp; `mktemp -d` makes one under TMPDIR). The account's home
# is never skipped.
sub holds_home {
    my ($p) = @_;
    my $r = _real($p) // return undef;
    $r =~ s{(?<=.)/+\z}{};
    my $rid = _id($r);
    my $acct = _real($REAL{account});
    $acct =~ s{(?<=.)/+\z}{} if defined $acct;
    my $st = defined $START_TMPDIR && !dotdot($START_TMPDIR) ? _real($START_TMPDIR) : undef;
    $st =~ s{/+\z}{} if defined $st;
    # a start TMPDIR of / (empty here) holds every home: it makes none a throwaway one (0.1.3)
    $st = undef if defined $st && $st eq '';
    for my $h (sort keys %{ $REAL{homes} || {} }) {
        my $own = defined $acct && ($h eq $acct || (_id($h) ne '' && _id($h) eq _id($acct)));
        next if !$own && (throwaway($h) || (defined $st && index($h, "$st/") == 0));
        my @up;
        for (my $d = $h; $d ne ''; $d =~ s{/[^/]*\z}{}) { push @up, $d }
        push @up, '/';
        return $h if grep { $_ eq $r || ($rid ne '' && _id($_) eq $rid) } @up;
    }
    return undef;
}

# add_throwaway(path...): more THROWAWAY folders
sub add_throwaway {
    push @THROWAWAY, grep { defined } @_;
    return;
}

# throwaway(path) -> 1 when the path's real path lies strictly under a THROWAWAY folder (by text:
# both are real paths), else 0
sub throwaway {
    my $r = _real($_[0]) // return 0;
    for my $t (@THROWAWAY) {
        my $rt = _real($t) // next;
        $rt =~ s{/+\z}{};
        next if $rt eq '';    # a THROWAWAY folder of / would hold every path (0.1.3)
        return 1 if index($r, "$rt/") == 0;
    }
    return 0;
}

# real_set(home => path, account => path, config_dir => path, given => {name => value}) -> the
# %REAL of those folders (see %REAL; a leading ~ in config_dir or a given value reads as home, as
# the helper's settings::config_dir reads CLAUDE_CONFIG_DIR)
sub real_set {
    my (%a) = @_;
    my $tilde = sub { my $v = $_[0]; $v =~ s{\A~(?=/|\z)}{$a{home}} if defined $v && defined $a{home}; $v };
    my $cd = $tilde->($a{config_dir});
    my %r = (home => $a{home}, account => $a{account}, config_dir => $cd, given => { %{ $a{given} || {} } });
    $r{homes} = _ids($a{home}, $a{account});
    $r{configs} = _ids((map { "$_/.claude" } keys %{ $r{homes} }), $cd);
    my @given = map { $tilde->($_) } grep { defined } values %{ $r{given} };
    $r{states} = _ids((map { ("$_/.local", "$_/.cache", "$_/.config") } keys %{ $r{homes} }), @given);
    return %r;
}

# _id(path) -> "dev:ino" of what the path leads to, '' when nothing is there
sub _id {
    my @s = stat($_[0]);
    return @s ? "$s[0]:$s[1]" : '';
}

# _resolve(path) -> where the kernel takes an absolute path: each link followed as it comes,
# a dangling one too (its target read as text: a file written through it lands there), `..`
# applied after the links before it, the missing rest kept as text; undef past 40 links (a link
# loop, which leads nowhere). util::real_path stops at a dangling link and reads it as a plain
# name, so $TMP/L with L -> ~/.local/state/x (no x yet) read as a temp path.
sub _resolve {
    my ($p) = @_;
    return undef unless defined $p && $p =~ m{\A/};
    my @todo = grep { $_ ne '' && $_ ne '.' } split m{/+}, $p;
    my ($cur, $hops) = ('', 0);
    while (@todo) {
        my $c = shift @todo;
        next if $c eq '.';
        if ($c eq '..') { $cur =~ s{/[^/]*\z}{}; next }
        my $n = "$cur/$c";
        if (-l $n) {
            return undef if ++$hops > 40;
            my $t = readlink($n) // return undef;
            unshift @todo, grep { $_ ne '' && $_ ne '.' } split m{/+}, $t;
            $cur = '' if $t =~ m{\A/};
            next;
        }
        $cur = $n;
    }
    return $cur eq '' ? '/' : $cur;
}

# _real(path) -> the real path of an absolute path (_resolve, then util::real_path for the case
# the file system gives the folders that exist), undef for a relative one or a link loop
sub _real {
    my $r = _resolve($_[0]) // return undef;
    return util::real_path($r);
}

# _ids(path...) -> {real path => _id} of the absolute paths without a `..` part
sub _ids {
    my %m;
    for my $p (grep { defined && m{\A/} && !dotdot($_) } @_) {
        my $r = _real($p) // next;
        $r =~ s{(?<=.)/+\z}{};
        $m{$r} = _id($r);
    }
    return \%m;
}

# drop_env(env hash): drops the caller's Claude Code, XDG, helper, git and shell start-up
# variables (DROP_RE), so a runner started inside a Claude Code session or a plugin hook passes
# none of them (its CLAUDE_PLUGIN_DATA, XDG_STATE_HOME, BASH_ENV, ...) to a case or child.
# Returns the names dropped.
sub drop_env {
    my ($env) = @_;
    my @k = sort grep { $_ =~ $DROP_RE } keys %$env;
    delete @{$env}{@k};
    return @k;
}

# fresh_env(home) -> a fresh environment for a runner's own children: PATH, TMPDIR, the locale,
# the account names, the shell, the terminal and the perl library path from this process
# (KEEP_RE), and HOME the given temp folder; nothing else of the caller's.
sub fresh_env {
    my ($home) = @_;
    my %e = map { ($_ => $ENV{$_}) } grep { $_ =~ $KEEP_RE } keys %ENV;
    $e{HOME} = $home;
    return \%e;
}

# add_temp_root(path...): more temp folders (the repo's tmp/ of a --repo-tmp run); dies, as
# check_temp_root, for one that is relative, has a `..` part, lies at or under a real config or
# state folder or lies at or above a real home
sub add_temp_root {
    check_temp_root($_, 'temp folder') for grep { defined } @_;
    push @EXTRA_TEMP, grep { defined } @_;
    @TEMP_ROOTS = ();
    return;
}

# dotdot(path) -> 1 when a part of the path is `..`. util::real_path folds `..` as text before it
# follows any link, but the kernel applies `..` after the link: $TMP/L/.. with L a link into the
# real home is the real home for a child, $TMP for real_path. The guard reads no such path.
sub dotdot {
    my ($p) = @_;
    return (grep { $_ eq '..' } split m{/+}, $p // '') ? 1 : 0;
}

# under_temp(path) -> 1 when the path is absolute with no `..` part and its real path lies
# strictly under a temp folder (a folder whose name only begins with a temp folder's is not).
sub under_temp {
    my ($p) = @_;
    die "homeguard: init() not called\n" unless $INIT;
    return 0 unless defined $p && $p =~ m{\A/} && !dotdot($p);
    my $r = _real($p) // return 0;
    @TEMP_ROOTS = grep { $_ ne '' } map { (my $t = _real($_) // '') =~ s{/+\z}{}; $t }
                  grep { defined && m{\A/} && !dotdot($_) } ($START_TMPDIR, '/tmp', @EXTRA_TEMP) unless @TEMP_ROOTS;
    return (grep { index($r, "$_/") == 0 } @TEMP_ROOTS) ? 1 : 0;
}

# _hit(path, {real path => id}, under) -> 1 when the path's real path is one of the folders (by
# text or by device and inode), or, with `under`, lies under one: its real path or a parent of it
# (the real path holds no link, so its text parents are its parents) has a folder's id.
sub _hit {
    my ($p, $m, $under) = @_;
    my $r = _real($p) // return 0;
    return 1 if grep { $r eq $_ || ($under && index($r, "$_/") == 0) } keys %$m;
    my %ids = map { ($_ => 1) } grep { $_ ne '' } values %$m;
    return 0 unless %ids;
    for (my $d = $r; $d ne ''; $d =~ s{/[^/]*\z}{}) {
        my $i = _id($d);
        return 1 if $i ne '' && $ids{$i};
        last unless $under;
    }
    return 0;
}

# real_home(path) -> 1 when the path is a real home (by real path or by device and inode).
sub real_home { return _hit($_[0], $REAL{homes} || {}, 0) }

# real_config(path) -> 1 when the path is at or under a real config folder.
sub real_config { return _hit($_[0], $REAL{configs} || {}, 1) }

# real_state(path) -> 1 when the path is at or under a real state folder.
sub real_state { return _hit($_[0], $REAL{states} || {}, 1) }

# check(env, what): dies before `what` starts when its environment (a hash: the whole
# environment the child gets) leads into the owner's real HOME, config folder or state folders:
# HOME unset (the helper would use the account's home, util::home) or empty, not absolute (a
# child started in another folder reads it there) or with a `..` part (see dotdot), a real home
# (by real path or device and inode: a link to it, or another case of its name, is refused too)
# or not under a temp folder; CLAUDE_CONFIG_DIR set with a `..` part or not under a temp folder (a
# leading ~ read as the child's HOME), or at or under a real home's .claude or the config folder
# the runner started with (TMPDIR=$HOME puts the real ~/.claude under a "temp" folder); the config
# folder the child writes (CLAUDE_CONFIG_DIR, else $HOME/.claude) or its settings.json a dangling
# link, at or under a real config folder or not under a temp folder by real path (a temp HOME
# whose .claude links to the real one); a folder of HOME_DIRS under HOME ($HOME/.local,
# .local/state, .local/share, .cache, .config, where a child writes when the XDG variables are
# unset) that is a dangling link or leads by real path to a real config or state folder or outside
# temp; a PATH_VARS value (a leading ~ read as the child's HOME; empty, or a `${user_config.<key>}`
# the helper reads as unset, passes; so does a relative XDG one, which the XDG rule ignores) not
# absolute, with a `..` part, at or under a real config or state folder, or not under a temp
# folder. Then the link walk (_walk) over HOME, the config folder and each PATH_VARS folder: a
# link at any depth under them that leads (dangling or not) to a real home, into a real config or
# state folder or outside the temp folders. Links inside temp pass.
sub check {
    my ($env, $what) = @_;
    die "homeguard: init() not called\n" unless $INIT;
    my $h = $env->{HOME};
    die "HOME-GUARD: $what: no HOME (the helper would use the account's home); not started\n" unless defined $h;
    die "HOME-GUARD: $what: an empty HOME; not started\n" if $h eq '';
    die "HOME-GUARD: $what: HOME $h is not absolute (a child in another folder reads it there); not started\n" unless $h =~ m{\A/};
    die "HOME-GUARD: $what: HOME $h has a .. part (applied after links); not started\n" if dotdot($h);
    die "HOME-GUARD: $what: HOME $h is the real home; not started\n" if real_home($h);
    die "HOME-GUARD: $what: HOME $h is not under a temp folder; not started\n" unless under_temp($h);
    my $c = $env->{CLAUDE_CONFIG_DIR};
    my $cfg = "$h/.claude";
    if (defined $c && $c ne '') {
        (my $x = $c) =~ s{\A~(?=/|\z)}{$h};
        die "HOME-GUARD: $what: CLAUDE_CONFIG_DIR $c has a .. part (applied after links); not started\n" if dotdot($x);
        die "HOME-GUARD: $what: CLAUDE_CONFIG_DIR $c is the real config folder; not started\n" if $x =~ m{\A/} && real_config($x);
        die "HOME-GUARD: $what: CLAUDE_CONFIG_DIR $c is not under a temp folder; not started\n" unless $x =~ m{\A/} && under_temp($x);
        $cfg = $x;
    }
    for my $p ($cfg, "$cfg/settings.json") {
        die "HOME-GUARD: $what: $p is a dangling link; not started\n" if -l $p && !-e $p;
        die "HOME-GUARD: $what: $p leads to a real config folder; not started\n" if real_config($p);
        die "HOME-GUARD: $what: $p leads outside the temp folders; not started\n" unless under_temp($p);
    }
    for my $p (map { "$h/$_" } @HOME_DIRS) {
        die "HOME-GUARD: $what: $p is a dangling link; not started\n" if -l $p && !-e $p;
        die "HOME-GUARD: $what: $p leads to a real config folder; not started\n" if real_config($p);
        die "HOME-GUARD: $what: $p leads to a real state folder; not started\n" if real_state($p);
        die "HOME-GUARD: $what: $p leads outside the temp folders; not started\n" unless under_temp($p);
    }
    my @walk;
    for my $k (@PATH_VARS) {
        my $v = $env->{$k};
        next if !defined $v || $v eq '' || index($v, '${user_config.') == 0;
        (my $x = $v) =~ s{\A~(?=/|\z)}{$h};
        next if $x !~ m{\A/} && $k =~ /\AXDG_/;
        die "HOME-GUARD: $what: $k $v is not absolute (a child in another folder reads it there); not started\n" unless $x =~ m{\A/};
        die "HOME-GUARD: $what: $k $v has a .. part (applied after links); not started\n" if dotdot($x);
        die "HOME-GUARD: $what: $k $v is in a real config folder; not started\n" if real_config($x);
        die "HOME-GUARD: $what: $k $v is in a real state folder; not started\n" if real_state($x);
        die "HOME-GUARD: $what: $k $v is not under a temp folder; not started\n" unless under_temp($x);
        push @walk, $x;
    }
    _walk($what, $h, $cfg, @walk);
    return 1;
}

# _walk(what, folder...): dies before `what` starts when a link under the folders (HOME, the
# config folder, the state folders a child is given) leads (by _resolve: a dangling link by its
# target) to a real home, into a real config or state folder, or outside the temp folders. The
# named checks read only the folders themselves and HOME_DIRS, so $HOME/.local/state/<name> or
# $XDG_STATE_HOME/<name> linked into the real ~/.local/state let the helper write its handoffs and
# watch logs there. A link that stays inside temp passes, and the folder it leads to is walked too
# (once: by device and inode), so a temp folder that links on into the real home is refused as
# well; a link loop leads nowhere and passes. Bounded: more than WALK_MAX entries read in all, or
# a folder more than WALK_DEPTH folders down, refuses the child. A folder this process cannot list
# but can go through (mode 0300) refuses it too; one it cannot go through (0000) no child of the
# same user can write in, and is passed over.
sub _walk {
    my ($what, @roots) = @_;
    my (%seen, @q);
    my $n = 0;
    for my $root (@roots) {
        my $r = _real($root) // next;
        push @q, [$r, 0] if -d $r;
    }
    while (my $e = shift @q) {
        my ($d, $depth) = @$e;
        my $id = _id($d);
        next if $id eq '' || $seen{$id}++;
        my $dh;
        if (!opendir($dh, $d)) {
            next unless -x $d;
            die "HOME-GUARD: $what: $d cannot be listed, and a child can go through it (the link walk reads every such folder); not started\n";
        }
        my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $name (@names) {
            die "HOME-GUARD: $what: more than $WALK_MAX entries under HOME, the config folder and the state folders (the link walk's budget); not started\n"
                if ++$n > $WALK_MAX;
            my $p = $d eq '/' ? "/$name" : "$d/$name";
            if (-l $p) {
                my $t = _resolve($p) // next;
                die "HOME-GUARD: $what: $p leads to a real home; not started\n" if real_home($t);
                die "HOME-GUARD: $what: $p leads to a real config folder; not started\n" if real_config($t);
                die "HOME-GUARD: $what: $p leads to a real state folder; not started\n" if real_state($t);
                die "HOME-GUARD: $what: $p leads outside the temp folders; not started\n" unless under_temp($t);
                push @q, [_real($t), $depth + 1] if -d $t;
                next;
            }
            next unless -d _;
            die "HOME-GUARD: $what: $p lies more than $WALK_DEPTH folders down (the link walk's budget); not started\n" if $depth + 1 > $WALK_DEPTH;
            push @q, [$p, $depth + 1];
        }
    }
    return 1;
}

# case_home(path) -> the path, for a declared "home": dies unless a child given it as HOME passes
# check (a temp folder, never the real home).
sub case_home {
    my ($h) = @_;
    check({ HOME => $h }, 'declared home');
    return $h;
}

# self_rows(tmp, temp home) -> {real => {a %REAL}, home => the stand-in real HOME, account => the
# stand-in account home, rows => [...]}: the guard's self-test table, one for both runners
# (AT-RN-06 in run.pl, AT-RN-07 in the watch driver). It makes stand-ins under tmp, a real HOME
# (Standin-Home), an account home (standin-acct, with .claude/settings.json), a config folder
# given (standin-cfg) and the state folders given (XDG_STATE_HOME, XDG_CACHE_HOME,
# CLAUDE_PLUGIN_DATA), and the links the rows read, all inside tmp: a runner runs the rows with
# `local %homeguard::REAL = %{ $t->{real} }`, so no link into the owner's real home or config
# folder is made and no row's child could reach them. Each row: {what, env (laid over the child's;
# undef drops a name), ok (started) or want (a regex of the refusal), temp (the temp folders, for
# @TEMP_ROOTS), budget ({max, depth}: the link walk's WALK_MAX and WALK_DEPTH for the row, {} for
# the defaults)}. The case-variant rows (another case of the stand-in's name, the same folder on a
# case-insensitive file system) are there only where the file system folds case. restore: the
# folders a runner gives mode 0700 again after the rows (one this process cannot list).
sub self_rows {
    my ($tmp, $th) = @_;
    my ($sh, $sa, $sc) = ("$tmp/Standin-Home", "$tmp/standin-acct", "$tmp/standin-cfg");
    util::mkdir_p($_) for ($th, "$sh/.claude", "$sh/.local/state", "$sh/.local/share", "$sh/.cache", "$sh/.config", "$sa/.claude", $sc,
                           "$tmp/standin-xdg-cache", "$tmp/t-root", "$tmp/outside-cfg", "$tmp/outside-state",
                           map { "$tmp/$_" } qw(h-clink h-slink/.claude h-tlink h-dangle cfg-in-temp t-root/h-olink t-root-x/h h-local
                                                h-state/.local h-share/.local h-cache h-config h-sdangle h-lcfg t-root/h-olocal h-tstate
                                                state-in-temp/state cache-in-temp));
    for my $f ("$sa/.claude/settings.json", "$tmp/cfg-in-temp/real.json") {
        next if -e $f;
        open(my $fh, '>', $f) or die "homeguard: write $f: $!\n";
        print $fh "{}\n";
        close $fh;
    }
    my %ln = ("$tmp/link-home" => $sa, "$tmp/link-in" => "$sa/.claude", "$tmp/h-clink/.claude" => "$sa/.claude",
              "$tmp/h-slink/.claude/settings.json" => "$sa/.claude/settings.json", "$tmp/h-tlink/.claude" => "$tmp/cfg-in-temp",
              "$tmp/cfg-in-temp/settings.json" => "$tmp/cfg-in-temp/real.json", "$tmp/h-dangle/.claude" => "$sa/.claude-gone",
              "$tmp/t-root/h-olink/.claude" => "$tmp/outside-cfg",
              # the folders a child writes under HOME with the XDG variables unset (HOME_DIRS)
              "$tmp/h-local/.local" => "$sh/.local", "$tmp/h-state/.local/state" => "$sh/.local/state",
              "$tmp/h-share/.local/share" => "$sh/.local/share", "$tmp/h-cache/.cache" => "$sh/.cache",
              "$tmp/h-config/.config" => "$sh/.config", "$tmp/h-sdangle/.cache" => "$sh/.cache-gone",
              "$tmp/h-lcfg/.config" => "$sa/.claude", "$tmp/t-root/h-olocal/.local" => "$tmp/outside-state",
              "$tmp/h-tstate/.local" => "$tmp/state-in-temp", "$tmp/h-tstate/.cache" => "$tmp/cache-in-temp");
    # the link walk (_walk): links at any depth under HOME, the config folder and the state folders
    util::mkdir_p($_) for ("$sh/.local/state/p", "$sh/.local/state/q", "$sh/.cache/trial", "$sh/.config/r", "$sa/.claude/handoffs",
                           map { "$tmp/$_" } qw(h-deep/.local/state h-deepcfg/.claude h-deepcache/.cache h-deep2/.local/state/p/q
                                                h-ddeep/.local/state h-ddout/.cache h-dhome/.local/share h-hop/.local/state hop-mid
                                                xs-deep hr-deep cfg-slink h-deepok/.local/state deep-in-temp/p h-dok/.local/state
                                                h-loop/.local h-many h-depth/a/b/c/d cfg-deep/plugins));
    for my $i (1 .. 8) { my $f = "$tmp/h-many/f$i"; next if -e $f; open(my $fh, '>', $f) or die "homeguard: write $f: $!\n"; close $fh }
    %ln = (%ln,
           # the review's scenarios: the helper's state folder under a temp HOME's .local/state
           # (A), the pre-0.1.2 handoff root under its .claude and the trial cache under its
           # .cache (B)
           "$tmp/h-deep/.local/state/p" => "$sh/.local/state/p", "$tmp/h-deepcfg/.claude/handoffs" => "$sa/.claude/handoffs",
           "$tmp/h-deepcache/.cache/trial" => "$sh/.cache/trial", "$tmp/h-deep2/.local/state/p/q/r" => "$sh/.config/r",
           "$tmp/h-ddeep/.local/state/p" => "$sh/.local/state/p-gone", "$tmp/h-ddout/.cache/x" => '/nonexistent-home-guard-deep/x',
           "$tmp/h-dhome/.local/share/h" => $sa, "$tmp/h-hop/.local/state/p" => "$tmp/hop-mid", "$tmp/hop-mid/q" => "$sh/.local/state/q",
           "$tmp/xs-deep/p" => "$sh/.local/state/p", "$tmp/hr-deep/.watch" => "$sh/.local/state/p",
           "$tmp/cfg-slink/settings.json" => "$sa/.claude/settings.json", "$tmp/h-deepok/.local/state/p" => "$tmp/deep-in-temp/p",
           "$tmp/h-dok/.local/state/p" => "$tmp/gone-in-temp", "$tmp/h-loop/.local/a" => "$tmp/h-loop/.local/b",
           "$tmp/h-loop/.local/b" => "$tmp/h-loop/.local/a", "$tmp/xs-dangle" => "$sh/.local/state/xs-gone",
           # a CLAUDE_CONFIG_DIR outside HOME is walked too
           "$tmp/cfg-deep/plugins/data" => "$sh/.local/state/p");
    for my $l (sort keys %ln) { -l $l or symlink($ln{$l}, $l) or die "homeguard: symlink $l: $!\n" }
    # a folder a child can go through but this process cannot list (not as root, who lists it)
    my @restore;
    if ($> != 0) { util::mkdir_p("$tmp/h-noread/.local/state"); chmod(0300, "$tmp/h-noread/.local/state"); push @restore, "$tmp/h-noread/.local/state" }
    my %real = real_set(home => $sh, account => $sa, config_dir => $sc,
                        given => { XDG_STATE_HOME => "$tmp/standin-xdg-state", XDG_CACHE_HOME => "$tmp/standin-xdg-cache",
                                   CLAUDE_PLUGIN_DATA => "$sa/.claude/plugins/data/p" });
    my $rp = sub { return util::real_path($_[0]) };
    my @rows = (
        ['the real HOME', { HOME => $sh }, qr/ is the real home; /],
        ["the account's home", { HOME => $sa }, qr/ is the real home; /],
        ['a link to the account home', { HOME => "$tmp/link-home" }, qr/ is the real home; /],
        ['no HOME', { HOME => undef }, qr/: no HOME /],
        ['an empty HOME', { HOME => '' }, qr/: an empty HOME; /],
        ['a relative HOME (read from a temp working folder)', { HOME => 'home-guard-rel' }, qr/ is not absolute /],
        ['a HOME outside the temp folders', { HOME => '/nonexistent-home-guard' }, qr/ is not under a temp folder; /],
        ['a HOME through a link into the real home and ..', { HOME => "$tmp/link-in/.." }, qr/ has a \.\. part /],
        ['CLAUDE_CONFIG_DIR at the real ~/.claude', { HOME => $th, CLAUDE_CONFIG_DIR => "$sa/.claude" }, qr/ is the real config folder; /],
        ['CLAUDE_CONFIG_DIR at the config folder the runner started with', { HOME => $th, CLAUDE_CONFIG_DIR => $sc }, qr/ is the real config folder; /],
        ['a relative CLAUDE_CONFIG_DIR', { HOME => $th, CLAUDE_CONFIG_DIR => 'cfg' }, qr/ is not under a temp folder; /],
        ['a CLAUDE_CONFIG_DIR outside the temp folders', { HOME => $th, CLAUDE_CONFIG_DIR => '/nonexistent-config-guard' }, qr/ is not under a temp folder; /],
        ['a CLAUDE_CONFIG_DIR through a link into the real home and ..', { HOME => $th, CLAUDE_CONFIG_DIR => "$tmp/link-in/../.claude" }, qr/ has a \.\. part /],
        ['a temp HOME whose .claude links to the real one', { HOME => "$tmp/h-clink" }, qr/ leads to a real config folder; /],
        ['a temp HOME whose settings.json links to the real one', { HOME => "$tmp/h-slink" }, qr/ leads to a real config folder; /],
        ['a temp HOME whose .claude is a dangling link into a stand-in folder', { HOME => "$tmp/h-dangle" }, qr/ is a dangling link; /],
        ['a temp HOME whose .claude links outside temp to a folder that is no config folder', { HOME => "$tmp/t-root/h-olink" },
         qr/\.claude leads outside the temp folders; /, [$rp->("$tmp/t-root")]],
        ["TMPDIR the account's home: CLAUDE_CONFIG_DIR at its .claude", { HOME => "$sa/home-guard-none", CLAUDE_CONFIG_DIR => "$sa/.claude" },
         qr/ is the real config folder; /, [$rp->($sa)]],
        ['a HOME in a folder that shares a temp folder\'s name as a prefix', { HOME => "$tmp/t-root-x/h" }, qr/ is not under a temp folder; /,
         [$rp->("$tmp/t-root")]],
        ['a temp HOME whose .local links to the real one', { HOME => "$tmp/h-local" }, qr{/\.local leads to a real state folder; }],
        ['a temp HOME whose .local/state links to the real one', { HOME => "$tmp/h-state" }, qr{/\.local/state leads to a real state folder; }],
        ['a temp HOME whose .local/share links to the real one', { HOME => "$tmp/h-share" }, qr{/\.local/share leads to a real state folder; }],
        ['a temp HOME whose .cache links to the real one', { HOME => "$tmp/h-cache" }, qr{/\.cache leads to a real state folder; }],
        ['a temp HOME whose .config links to the real one', { HOME => "$tmp/h-config" }, qr{/\.config leads to a real state folder; }],
        ['a temp HOME whose .cache is a dangling link into a stand-in folder', { HOME => "$tmp/h-sdangle" }, qr{/\.cache is a dangling link; }],
        ['a temp HOME whose .config links to the real config folder', { HOME => "$tmp/h-lcfg" }, qr{/\.config leads to a real config folder; }],
        ['a temp HOME whose .local links outside temp to a folder that is no state folder', { HOME => "$tmp/t-root/h-olocal" },
         qr{/\.local leads outside the temp folders; }, [$rp->("$tmp/t-root")]],
        ['XDG_STATE_HOME outside the temp folders', { HOME => $th, XDG_STATE_HOME => '/nonexistent-state-guard' }, qr/XDG_STATE_HOME \S+ is not under a temp folder; /],
        ['CLAUDE_PLUGIN_DATA in the real config folder', { HOME => $th, CLAUDE_PLUGIN_DATA => "$sa/.claude/plugins/data/p" }, qr/CLAUDE_PLUGIN_DATA \S+ is in a real config folder; /],
        ["XDG_STATE_HOME at the real home's .local/state", { HOME => $th, XDG_STATE_HOME => "$sh/.local/state" }, qr/XDG_STATE_HOME \S+ is in a real state folder; /],
        ['XDG_CACHE_HOME under the cache folder the runner started with', { HOME => $th, XDG_CACHE_HOME => "$tmp/standin-xdg-cache/x" }, qr/XDG_CACHE_HOME \S+ is in a real state folder; /],
        ["TMPDIR the real home: XDG_CACHE_HOME at its .cache", { HOME => "$sh/home-guard-none", XDG_CACHE_HOME => "$sh/.cache" },
         qr/XDG_CACHE_HOME \S+ is in a real state folder; /, [$rp->($sh)]],
        ["TMPDIR the real home: XDG_CONFIG_HOME at its .config", { HOME => "$sh/home-guard-none", XDG_CONFIG_HOME => "$sh/.config" },
         qr/XDG_CONFIG_HOME \S+ is in a real state folder; /, [$rp->($sh)]],
        ['a relative CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT', { HOME => $th, CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => 'rel/handoffs' }, qr/CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT \S+ is not absolute /],
        ['CLAUDE_PLUGIN_OPTION_LOG_DIR through a link into the real home and ..', { HOME => $th, CLAUDE_PLUGIN_OPTION_LOG_DIR => "$tmp/link-in/../logs" }, qr/CLAUDE_PLUGIN_OPTION_LOG_DIR \S+ has a \.\. part /],
        ['CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT outside the temp folders', { HOME => $th, CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT => '/nonexistent-disp-guard' }, qr/ is not under a temp folder; /],
        ['CLAUDE_CODE_TMPDIR outside the temp folders', { HOME => $th, CLAUDE_CODE_TMPDIR => '/nonexistent-cct-guard' }, qr/ is not under a temp folder; /],
    );
    # another case of the stand-ins' names: the same folders where the file system folds case
    my ($vh, $va) = map { my $v = $_; $v =~ s{([^/]+)\z}{ my $b = $1; $b eq uc $b ? lc $b : uc $b }e; $v } ($sh, $sa);
    if (_id($va) ne '' && _id($va) eq _id($sa)) {
        push @rows, ['the real HOME by another case of its name', { HOME => $vh }, qr/ is the real home; /],
                    ["TMPDIR another case of the account's home: CLAUDE_CONFIG_DIR at its .claude", { HOME => "$va/home-guard-none", CLAUDE_CONFIG_DIR => "$va/.claude" },
                     qr/ is the real config folder; /, [$rp->($va)]],
                    ["TMPDIR another case of the account's home: CLAUDE_PLUGIN_DATA in its .claude", { HOME => "$va/home-guard-none", CLAUDE_PLUGIN_DATA => "$va/.claude/plugins/data/p" },
                     qr/ is in a real config folder; /, [$rp->($va)]];
    }
    push @rows, (
        ["a temp HOME whose .local/state/<name> links into the real home's .local/state (scenario A)", { HOME => "$tmp/h-deep" },
         qr{/h-deep/\.local/state/p leads to a real state folder; }],
        ["a temp HOME whose .claude/handoffs links into the real ~/.claude (scenario B)", { HOME => "$tmp/h-deepcfg" },
         qr{/h-deepcfg/\.claude/handoffs leads to a real config folder; }],
        ["a temp HOME whose .cache/<name> links into the real home's .cache (scenario B)", { HOME => "$tmp/h-deepcache" },
         qr{/h-deepcache/\.cache/trial leads to a real state folder; }],
        ["a link four folders below a temp HOME into the real home's .config", { HOME => "$tmp/h-deep2" },
         qr{/h-deep2/\.local/state/p/q/r leads to a real state folder; }],
        ["a dangling link below a temp HOME into the real home's .local/state", { HOME => "$tmp/h-ddeep" },
         qr{/h-ddeep/\.local/state/p leads to a real state folder; }],
        ['a dangling link below a temp HOME to a folder outside temp', { HOME => "$tmp/h-ddout" }, qr{/h-ddout/\.cache/x leads outside the temp folders; }],
        ["a link below a temp HOME to the account's home", { HOME => "$tmp/h-dhome" }, qr{/h-dhome/\.local/share/h leads to a real home; }],
        ['a link below a temp HOME to a temp folder that links on into the real state folder', { HOME => "$tmp/h-hop" },
         qr{/hop-mid/q leads to a real state folder; }],
        ["XDG_STATE_HOME under temp whose <name> links into the real home's .local/state", { HOME => $th, XDG_STATE_HOME => "$tmp/xs-deep" },
         qr{/xs-deep/p leads to a real state folder; }],
        ["a handoff root under temp whose .watch links into the real home's .local/state", { HOME => $th, CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => "$tmp/hr-deep" },
         qr{/hr-deep/\.watch leads to a real state folder; }],
        ["XDG_STATE_HOME a dangling link into the real home's .local/state", { HOME => $th, XDG_STATE_HOME => "$tmp/xs-dangle" },
         qr/XDG_STATE_HOME \S+ is in a real state folder; /],
        ['a CLAUDE_CONFIG_DIR under temp whose settings.json links to the real one', { HOME => $th, CLAUDE_CONFIG_DIR => "$tmp/cfg-slink" },
         qr{/cfg-slink/settings\.json leads to a real config folder; }],
        ["a CLAUDE_CONFIG_DIR under temp outside HOME with a link below it into the real home's .local/state",
         { HOME => $th, CLAUDE_CONFIG_DIR => "$tmp/cfg-deep" }, qr{/cfg-deep/plugins/data leads to a real state folder; }],
        ["XDG_DATA_HOME at the real home's .local/share", { HOME => $th, XDG_DATA_HOME => "$sh/.local/share" },
         qr/XDG_DATA_HOME \S+ is in a real state folder; /],
        ['a temp HOME with more entries than the link walk reads', { HOME => "$tmp/h-many" }, qr/ more than 5 entries under HOME, /, undef, undef, { max => 5 }],
        ['a temp HOME with folders deeper than the link walk goes', { HOME => "$tmp/h-depth" }, qr{/h-depth/a/b/c lies more than 2 folders down }, undef, undef,
         { depth => 2 }],
    );
    push @rows, ['a temp HOME with a folder a child can go through but the guard cannot list', { HOME => "$tmp/h-noread" },
                 qr{/h-noread/\.local/state cannot be listed, }] if @restore;
    push @rows, map { [@$_[0, 1], undef, undef, 'ok'] } (
        ['a temp HOME', { HOME => $th }],
        ['a CLAUDE_CONFIG_DIR under the temp HOME', { HOME => $th, CLAUDE_CONFIG_DIR => '~/.claude' }],
        ['an absolute CLAUDE_CONFIG_DIR under the temp HOME', { HOME => $th, CLAUDE_CONFIG_DIR => "$th/.claude" }],
        ['a temp HOME whose .claude and settings.json link inside temp', { HOME => "$tmp/h-tlink" }],
        ['a temp HOME whose .local and .cache link inside temp', { HOME => "$tmp/h-tstate" }],
        ['state folders under temp', { HOME => $th, XDG_STATE_HOME => "$th/.local/state", XDG_CACHE_HOME => "$th/.cache", CLAUDE_PLUGIN_DATA => "$th/data",
                                       CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => '~/.local/state/x/handoffs', CLAUDE_PLUGIN_OPTION_LOG_DIR => "$tmp/logs" }],
        ['state values the helper reads as unset', { HOME => $th, XDG_STATE_HOME => 'rel/state', CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => '${user_config.handoff_root}',
                                                     CLAUDE_PLUGIN_OPTION_LOG_DIR => '' }],
        ['a link two folders below a temp HOME into temp', { HOME => "$tmp/h-deepok" }],
        ['a dangling link below a temp HOME into temp', { HOME => "$tmp/h-dok" }],
        ['a link loop below a temp HOME', { HOME => "$tmp/h-loop" }],
    );
    return { real => \%real, home => $sh, account => $sa, restore => \@restore,
             rows => [ map { { what => $_->[0], env => $_->[1], want => $_->[2], temp => $_->[3], ok => $_->[4] ? 1 : 0, budget => $_->[5] || {} } } @rows ] };
}

# self_row_errs(row, start...) -> the row's failures; a start is [label (the child kind tried:
# 'helper call', 'cli child', ...), started (true when the child started), error (the $@ of the
# attempt, '' or undef when none)]: an `ok` row with a refusal, any other row that started or
# died without its `HOME-GUARD: ... <want>` line.
sub self_row_errs {
    my ($row, @starts) = @_;
    my @e;
    for my $s (@starts) {
        my ($label, $started, $err) = @$s;
        if ($row->{ok}) { push @e, "$row->{what}: the $label was refused: $err" if !$started; next }
        if ($started) { push @e, "$row->{what}: the $label started, want HOME-GUARD"; next }
        push @e, "$row->{what}: the $label died with '" . ($err // '') . "', want HOME-GUARD ... $row->{want}"
            unless ($err // '') =~ /\AHOME-GUARD: / && $err =~ $row->{want};
    }
    return @e;
}

# temp_root_rows(tmp) -> {tried => [what...], errs => [failure...]}: check_temp_root's start-up
# decision on a TMPDIR at or above a home, one table for both runners (AT-RN-06, AT-RN-07), with
# stand-ins under tmp/tr (no THROWAWAY folder, the start TMPDIR set per row): a TMPDIR that holds a
# HOME given made in it (as `mktemp -d` makes one under TMPDIR) is taken; one that is that HOME,
# the account's home (also under the start TMPDIR: the account's home is never a throwaway one) or
# holds it, or is / is refused (also a link to /, also with no account home known, and a start
# TMPDIR of / makes no HOME given a throwaway one, 0.1.3); so is another case of the HOME given's,
# the account home's or its parent's name where the file system folds case (only the device and
# inode compare sees those).
sub temp_root_rows {
    my ($tmp) = @_;
    my $b = "$tmp/tr";
    my ($g, $a) = ("$b/t/home", "$b/acct");
    util::mkdir_p($_) for ($g, $a);
    my %real = real_set(home => $g, account => $a);
    my $vary = sub { my $v = $_[0]; $v =~ s{([^/]+)\z}{ my $x = $1; $x eq uc $x ? lc $x : uc $x }e; $v };
    my $held = qr/ is at or above the real home /;
    # 0.1.3: a start TMPDIR of / makes no home a throwaway one, and / is refused even with no
    # account home known (a host whose user has no passwd entry); a link to / is / too
    my %no_acct = real_set(home => $g);
    my $lroot = "$b/lroot";
    symlink('/', $lroot) or die "homeguard: symlink $lroot: $!\n" unless -l $lroot;
    # [what, start TMPDIR, the folder checked, want (undef: taken), the %REAL (default: %real)]
    my @rows = (["a TMPDIR that holds a HOME given made in it", "$b/t", "$b/t", undef],
                ['a TMPDIR at the HOME given', $g, $g, $held],
                ["a TMPDIR at the account's home under the start TMPDIR", $b, $a, $held],
                ["a TMPDIR that holds the account's home", $b, $b, $held],
                ['a TMPDIR of /', '/', '/', $held],
                ['a TMPDIR of / with no account home known', '/', '/', $held, \%no_acct],
                ['a link to / with no account home known', '/', $lroot, $held, \%no_acct],
                ['a temp root at the HOME given while the start TMPDIR is /', '/', $g, $held],
                ['a temp root that holds the HOME given while the start TMPDIR is /', '/', "$b/t", $held, \%no_acct]);
    my ($vg, $va, $vb) = map { $vary->($_) } ($g, $a, $b);
    if (_id($va) ne '' && _id($va) eq _id($a)) {
        push @rows, ['a TMPDIR at the HOME given by another case of its name', $vg, $vg, $held],
                    ["a TMPDIR at the account's home by another case of its name", $b, $va, $held],
                    ["a TMPDIR that holds the account's home by another case of its name", $b, $vb, $held];
    }
    my (@tried, @e);
    for my $r (@rows) {
        my ($what, $st, $p, $want, $rs) = @$r;
        push @tried, $what;
        local %REAL = $rs ? %$rs : %real;
        local @THROWAWAY = ();
        local $START_TMPDIR = $st;
        my $err = eval { check_temp_root($p, 'TMPDIR'); 1 } ? '' : $@;
        if (!$want) { push @e, "$what ($p): refused: $err" if $err ne ''; next }
        push @e, "$what ($p): " . ($err eq '' ? 'taken' : "died with '$err'") . ", want HOME-GUARD ... $want"
            unless $err =~ /\AHOME-GUARD: TMPDIR / && $err =~ $want;
    }
    return { tried => \@tried, errs => \@e };
}

1;

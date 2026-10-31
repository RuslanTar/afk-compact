package homeguard;
# tests/helper/homeguard.pm: HOME-GUARD (0.1.2), the one guard of every test runner here that
# starts children: the helper case runner (tests/helper/run.pl) and the watch driver
# (tests/helper/cases/watch/_driver/run-watch.pl, its T.pm). No case and no child of theirs
# reaches the owner's real HOME or Claude Code config folder (a kit test elsewhere ran a planted
# hook with the real HOME and wiped ~/.claude/settings.json to "{}"; lib/settings_write.pm writes
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json).
#
# A runner calls init() once, before it localises anything (the real HOME, the account's home
# and the CLAUDE_CONFIG_DIR given are read there), add_temp_root() for a temp folder of its own
# outside the system one, then check(env, what) before each child it starts. Needs core's
# util.pm (plugin/helper/lib) loaded: paths are compared by util::real_path.
use strict;
use warnings;

our ($REAL_HOME, $REAL_CONFIG_DIR, $ACCOUNT_HOME, $START_TMPDIR);
# the real homes and the real config folders (real paths): each real home's .claude and the
# CLAUDE_CONFIG_DIR given
our (%REAL_HOMES, %REAL_CONFIGS);
# the temp folders a child's HOME and CLAUDE_CONFIG_DIR may lie under: the system temp folder as
# given at start, /tmp, and each added one (real paths, filled on first use; a self-test may
# `local` it)
our (@EXTRA_TEMP, @TEMP_ROOTS);
my $INIT;

sub init {
    return if $INIT++;
    $REAL_HOME = $ENV{HOME};
    $REAL_CONFIG_DIR = $ENV{CLAUDE_CONFIG_DIR};
    $ACCOUNT_HOME = (getpwuid($<))[7];
    $START_TMPDIR = $ENV{TMPDIR};
    %REAL_HOMES = map { (util::real_path($_) => 1) } grep { defined && m{\A/} } ($REAL_HOME, $ACCOUNT_HOME);
    %REAL_CONFIGS = map { (util::real_path($_) => 1) } ((map { "$_/.claude" } keys %REAL_HOMES), grep { defined && m{\A/} } $REAL_CONFIG_DIR);
    return;
}

# add_temp_root(path...): more temp folders (the repo's tmp/ of a --repo-tmp run)
sub add_temp_root {
    push @EXTRA_TEMP, grep { defined && m{\A/} } @_;
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
# strictly under a temp folder.
sub under_temp {
    my ($p) = @_;
    die "homeguard: init() not called\n" unless $INIT;
    return 0 unless defined $p && $p =~ m{\A/} && !dotdot($p);
    my $r = util::real_path($p) // return 0;
    @TEMP_ROOTS = grep { $_ ne '' } map { (my $t = util::real_path($_) // '') =~ s{/+\z}{}; $t }
                  grep { defined && m{\A/} } ($START_TMPDIR, '/tmp', @EXTRA_TEMP) unless @TEMP_ROOTS;
    return (grep { index($r, "$_/") == 0 } @TEMP_ROOTS) ? 1 : 0;
}

# real_config(path) -> 1 when the path's real path is at or under a real config folder.
sub real_config {
    my ($p) = @_;
    my $r = util::real_path($p) // return 0;
    return (grep { $r eq $_ || index($r, "$_/") == 0 } keys %REAL_CONFIGS) ? 1 : 0;
}

# check(env, what): dies before `what` starts when its environment (a hash: the whole
# environment the child gets) could reach the owner's real HOME or config folder: HOME unset (the
# helper would use the account's home, util::home) or empty, not absolute (a child started in
# another folder reads it there) or with a `..` part (see dotdot), the real HOME or the account's
# home (by real path: a link to it is refused too) or not under a temp folder; CLAUDE_CONFIG_DIR
# set with a `..` part or not under a temp folder (a leading ~ read as the child's HOME), or at or
# under a real home's .claude or the config folder the runner started with (by real path:
# TMPDIR=$HOME puts the real ~/.claude under a "temp" folder); the config folder the child writes
# (CLAUDE_CONFIG_DIR, else $HOME/.claude) or its settings.json at or under a real config folder or
# not under a temp folder by real path (a temp HOME whose .claude links to the real one), or a
# dangling link (where it leads is not read here). Links inside temp pass.
sub check {
    my ($env, $what) = @_;
    die "homeguard: init() not called\n" unless $INIT;
    my $h = $env->{HOME};
    die "HOME-GUARD: $what: no HOME (the helper would use the account's home); not started\n" unless defined $h;
    die "HOME-GUARD: $what: an empty HOME; not started\n" if $h eq '';
    die "HOME-GUARD: $what: HOME $h is not absolute (a child in another folder reads it there); not started\n" unless $h =~ m{\A/};
    die "HOME-GUARD: $what: HOME $h has a .. part (applied after links); not started\n" if dotdot($h);
    my $rh = util::real_path($h) // '';
    die "HOME-GUARD: $what: HOME $h is the real home; not started\n" if $REAL_HOMES{$rh};
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
    return 1;
}

# case_home(path) -> the path, for a declared "home": dies unless a child given it as HOME passes
# check (a temp folder, never the real home).
sub case_home {
    my ($h) = @_;
    check({ HOME => $h }, 'declared home');
    return $h;
}

1;

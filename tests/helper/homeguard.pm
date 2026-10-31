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

# under_temp(path) -> 1 when the path's real path lies strictly under a temp folder.
sub under_temp {
    my ($p) = @_;
    die "homeguard: init() not called\n" unless $INIT;
    my $r = util::real_path($p) // return 0;
    @TEMP_ROOTS = grep { $_ ne '' } map { (my $t = util::real_path($_) // '') =~ s{/+\z}{}; $t }
                  grep { defined && m{\A/} } ($START_TMPDIR, '/tmp', @EXTRA_TEMP) unless @TEMP_ROOTS;
    return (grep { index($r, "$_/") == 0 } @TEMP_ROOTS) ? 1 : 0;
}

# check(env, what): dies before `what` starts when its environment (a hash: the whole
# environment the child gets) could reach the owner's real HOME or config folder: HOME unset or
# empty (the helper would use the account's home, util::home), HOME the real HOME or the
# account's home (by real path: a link to it is refused too) or not under a temp folder;
# CLAUDE_CONFIG_DIR set and not under a temp folder (a leading ~ read as the child's HOME), or at
# or under a real home's .claude or the config folder the runner started with (by real path:
# TMPDIR=$HOME puts the real ~/.claude under a "temp" folder).
sub check {
    my ($env, $what) = @_;
    die "homeguard: init() not called\n" unless $INIT;
    my $h = $env->{HOME};
    die "HOME-GUARD: $what: no HOME (the helper would use the account's home); not started\n" unless defined $h && $h ne '';
    my $rh = util::real_path($h) // '';
    die "HOME-GUARD: $what: HOME $h is the real home; not started\n" if $REAL_HOMES{$rh};
    die "HOME-GUARD: $what: HOME $h is not under a temp folder; not started\n" unless under_temp($h);
    my $c = $env->{CLAUDE_CONFIG_DIR};
    if (defined $c && $c ne '') {
        (my $x = $c) =~ s{\A~(?=/|\z)}{$h};
        my $rc = $x =~ m{\A/} ? util::real_path($x) // '' : '';
        die "HOME-GUARD: $what: CLAUDE_CONFIG_DIR $c is the real config folder; not started\n"
            if grep { $rc eq $_ || index($rc, "$_/") == 0 } keys %REAL_CONFIGS;
        die "HOME-GUARD: $what: CLAUDE_CONFIG_DIR $c is not under a temp folder; not started\n" unless $x =~ m{\A/} && under_temp($x);
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

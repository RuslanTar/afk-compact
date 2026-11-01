package homeguard;
# tests/helper/homeguard.pm: HOME-GUARD (0.1.2), the one guard of every test runner here that
# starts children: the helper case runner (tests/helper/run.pl) and the watch driver
# (tests/helper/cases/watch/_driver/run-watch.pl, its T.pm). No case and no child of theirs
# reaches the owner's real HOME, Claude Code config folder or state folders (a kit test elsewhere
# ran a planted hook with the real HOME and wiped ~/.claude/settings.json to "{}";
# lib/settings_write.pm writes ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json, and the helper
# writes its handoff root and watch logs under $XDG_STATE_HOME, CLAUDE_PLUGIN_DATA and the
# CLAUDE_PLUGIN_OPTION_* folders).
#
# A runner calls init() once, before it changes its environment (the real HOME, the account's
# home, the CLAUDE_CONFIG_DIR and the state folders given are read there), then drops the
# caller's Claude Code, XDG and helper variables (drop_env) or starts from a fresh environment
# (fresh_env), add_temp_root() for a temp folder of its own outside the system one, then
# check(env, what) before each child it starts. Needs core's util.pm (plugin/helper/lib) loaded:
# paths are compared by util::real_path, and by device and inode (a case-insensitive file system
# reads /users/me as /Users/me, which a text compare misses).
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
# the temp folders a child's HOME and CLAUDE_CONFIG_DIR may lie under: the system temp folder as
# given at start, /tmp, and each added one (real paths, filled on first use; a self-test may
# `local` it)
our (@EXTRA_TEMP, @TEMP_ROOTS);
# the folders a child writes besides HOME and CLAUDE_CONFIG_DIR, as variables: the XDG base
# folders (the helper's default handoff root reads $XDG_STATE_HOME, the launcher's cache
# $XDG_CACHE_HOME), the plugin's data folder (hook.pl's last-version), its folder options, and
# Claude Code's temp folder
our @PATH_VARS = qw(XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR
                    CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT CLAUDE_PLUGIN_OPTION_LOG_DIR
                    CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT CLAUDE_CODE_TMPDIR);
# drop_env drops these names: Claude Code's (CLAUDECODE, CLAUDE_CONFIG_DIR, CLAUDE_PLUGIN_*,
# CLAUDE_CODE_*, ...), the XDG ones and the helper's own (STORE_*)
our $DROP_RE = qr/\A(?:CLAUDE|XDG_|STORE_)/;
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
    return;
}

# real_set(home => path, account => path, config_dir => path, given => {name => value}) -> the
# %REAL of those folders (see %REAL; a leading ~ in a given value reads as home)
sub real_set {
    my (%a) = @_;
    my %r = (home => $a{home}, account => $a{account}, config_dir => $a{config_dir}, given => { %{ $a{given} || {} } });
    $r{homes} = _ids($a{home}, $a{account});
    $r{configs} = _ids((map { "$_/.claude" } keys %{ $r{homes} }), $a{config_dir});
    my @given = map { my $v = $_; $v =~ s{\A~(?=/|\z)}{$a{home}} if defined $a{home}; $v } grep { defined } values %{ $r{given} };
    $r{states} = _ids((map { ("$_/.local", "$_/.cache", "$_/.config") } keys %{ $r{homes} }), @given);
    return %r;
}

# _id(path) -> "dev:ino" of what the path leads to, '' when nothing is there
sub _id {
    my @s = stat($_[0]);
    return @s ? "$s[0]:$s[1]" : '';
}

# _ids(path...) -> {real path => _id} of the absolute paths without a `..` part
sub _ids {
    my %m;
    for my $p (grep { defined && m{\A/} && !dotdot($_) } @_) {
        my $r = util::real_path($p) // next;
        $r =~ s{(?<=.)/+\z}{};
        $m{$r} = _id($r);
    }
    return \%m;
}

# drop_env(env hash): drops the caller's Claude Code, XDG and helper variables (DROP_RE), so a
# runner started inside a Claude Code session or a plugin hook passes none of them (its
# CLAUDE_PLUGIN_DATA, XDG_STATE_HOME, ...) to a case or child. Returns the names dropped.
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

# _hit(path, {real path => id}, under) -> 1 when the path's real path is one of the folders (by
# text or by device and inode), or, with `under`, lies under one: its real path or a parent of it
# (the real path holds no link, so its text parents are its parents) has a folder's id.
sub _hit {
    my ($p, $m, $under) = @_;
    my $r = util::real_path($p) // return 0;
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
# environment the child gets) could reach the owner's real HOME, config folder or state folders:
# HOME unset (the helper would use the account's home, util::home) or empty, not absolute (a
# child started in another folder reads it there) or with a `..` part (see dotdot), a real home
# (by real path or device and inode: a link to it, or another case of its name, is refused too)
# or not under a temp folder; CLAUDE_CONFIG_DIR set with a `..` part or not under a temp folder (a
# leading ~ read as the child's HOME), or at or under a real home's .claude or the config folder
# the runner started with (TMPDIR=$HOME puts the real ~/.claude under a "temp" folder); the config
# folder the child writes (CLAUDE_CONFIG_DIR, else $HOME/.claude) or its settings.json at or under
# a real config folder or not under a temp folder by real path (a temp HOME whose .claude links
# to the real one), or a dangling link (where it leads is not read here); a PATH_VARS value (a
# leading ~ read as the child's HOME; empty, or a `${user_config.<key>}` the helper reads as unset,
# passes; so does a relative XDG one, which the XDG rule ignores) not absolute, with a `..` part,
# at or under a real config or state folder, or not under a temp folder. Links inside temp pass.
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
# @TEMP_ROOTS)}. The case-variant rows (another case of the stand-in's name, the same folder on a
# case-insensitive file system) are there only where the file system folds case.
sub self_rows {
    my ($tmp, $th) = @_;
    my ($sh, $sa, $sc) = ("$tmp/Standin-Home", "$tmp/standin-acct", "$tmp/standin-cfg");
    util::mkdir_p($_) for ($th, "$sh/.claude", "$sh/.local/state", "$sa/.claude", $sc, "$tmp/standin-xdg-cache", "$tmp/t-root",
                           "$tmp/outside-cfg", map { "$tmp/$_" } qw(h-clink h-slink/.claude h-tlink h-dangle cfg-in-temp t-root/h-olink));
    for my $f ("$sa/.claude/settings.json", "$tmp/cfg-in-temp/real.json") {
        next if -e $f;
        open(my $fh, '>', $f) or die "homeguard: write $f: $!\n";
        print $fh "{}\n";
        close $fh;
    }
    my %ln = ("$tmp/link-home" => $sa, "$tmp/link-in" => "$sa/.claude", "$tmp/h-clink/.claude" => "$sa/.claude",
              "$tmp/h-slink/.claude/settings.json" => "$sa/.claude/settings.json", "$tmp/h-tlink/.claude" => "$tmp/cfg-in-temp",
              "$tmp/cfg-in-temp/settings.json" => "$tmp/cfg-in-temp/real.json", "$tmp/h-dangle/.claude" => "$sa/.claude-gone",
              "$tmp/t-root/h-olink/.claude" => "$tmp/outside-cfg");
    for my $l (sort keys %ln) { -l $l or symlink($ln{$l}, $l) or die "homeguard: symlink $l: $!\n" }
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
        ['XDG_STATE_HOME outside the temp folders', { HOME => $th, XDG_STATE_HOME => '/nonexistent-state-guard' }, qr/XDG_STATE_HOME \S+ is not under a temp folder; /],
        ['CLAUDE_PLUGIN_DATA in the real config folder', { HOME => $th, CLAUDE_PLUGIN_DATA => "$sa/.claude/plugins/data/p" }, qr/CLAUDE_PLUGIN_DATA \S+ is in a real config folder; /],
        ["XDG_STATE_HOME at the real home's .local/state", { HOME => $th, XDG_STATE_HOME => "$sh/.local/state" }, qr/XDG_STATE_HOME \S+ is in a real state folder; /],
        ['XDG_CACHE_HOME under the cache folder the runner started with', { HOME => $th, XDG_CACHE_HOME => "$tmp/standin-xdg-cache/x" }, qr/XDG_CACHE_HOME \S+ is in a real state folder; /],
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
                     qr/ is the real config folder; /, [$va]],
                    ["TMPDIR another case of the account's home: CLAUDE_PLUGIN_DATA in its .claude", { HOME => "$va/home-guard-none", CLAUDE_PLUGIN_DATA => "$va/.claude/plugins/data/p" },
                     qr/ is in a real config folder; /, [$va]];
    }
    push @rows, map { [@$_[0, 1], undef, undef, 'ok'] } (
        ['a temp HOME', { HOME => $th }],
        ['a CLAUDE_CONFIG_DIR under the temp HOME', { HOME => $th, CLAUDE_CONFIG_DIR => '~/.claude' }],
        ['an absolute CLAUDE_CONFIG_DIR under the temp HOME', { HOME => $th, CLAUDE_CONFIG_DIR => "$th/.claude" }],
        ['a temp HOME whose .claude and settings.json link inside temp', { HOME => "$tmp/h-tlink" }],
        ['state folders under temp', { HOME => $th, XDG_STATE_HOME => "$th/.local/state", XDG_CACHE_HOME => "$th/.cache", CLAUDE_PLUGIN_DATA => "$th/data",
                                       CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => '~/.local/state/x/handoffs', CLAUDE_PLUGIN_OPTION_LOG_DIR => "$tmp/logs" }],
        ['state values the helper reads as unset', { HOME => $th, XDG_STATE_HOME => 'rel/state', CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => '${user_config.handoff_root}',
                                                     CLAUDE_PLUGIN_OPTION_LOG_DIR => '' }],
    );
    return { real => \%real, home => $sh, account => $sa,
             rows => [ map { { what => $_->[0], env => $_->[1], want => $_->[2], temp => $_->[3], ok => $_->[4] ? 1 : 0 } } @rows ] };
}

# self_row_errs(row, error of the first start, error of the second, started?...) -> the row's
# failures: an `ok` row with a refusal, any other row that started or died without its
# `HOME-GUARD: ... <want>` line. Each start is [label, started, error].
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

1;

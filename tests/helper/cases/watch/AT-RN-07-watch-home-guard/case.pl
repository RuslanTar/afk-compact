# AT-RN-07 (HOME-GUARD, 0.1.2; AT-RN-06 is the core case runner's): the watch driver runs in a
# fresh environment with a temp HOME (no CLAUDE_CONFIG_DIR, CLAUDE*, XDG_*, GIT_* or STORE_* name
# of the caller's; STORE_TEST_MODE and STORE_TEST_NOW are the driver's own), each case with its
# own $HOME, and the real homes, config folder and state folders the guard read at start are the
# owner's. With stand-ins for those (homeguard::self_rows: a real HOME, an account home, a config
# folder and state folders given, all under $TMP, so no link into the real home or ~/.claude is
# made) it refuses, before the child starts, a `cli` child (run_child) and a fixture git child
# (T::_git) in every row of the guard's table (the same table as AT-RN-06: a real home or a link
# to it or another case of its name, no, an empty, a relative HOME or one outside temp, `..`
# through a link, a CLAUDE_CONFIG_DIR at a real config folder, relative or outside temp, or under
# temp with its settings.json linked to the real one, a temp HOME whose .claude or settings.json
# links to the real one, whose .claude is a dangling link or links outside temp, whose .local,
# .local/state, .local/share, .cache or .config links into the real home (or the real config
# folder), is a dangling link or links outside temp, a link at any depth below HOME or a state
# folder that leads, dangling or not, into the real home's folders or outside temp (the link
# walk, past its budget too), a HOME in a folder whose name a temp folder's begins, TMPDIR at the
# account's home or another case of it, or at the real home with XDG_CACHE_HOME or
# XDG_CONFIG_HOME at its .cache or .config, a state folder outside temp, relative, through `..`
# or in a real config or state folder). The `cli` child is `true` and the git child
# `git --version`, so a guard that lets one through starts nothing that reads or writes a home.
# The rows that pass start both. An inner driver run fails a case whose step moved HOME outside
# temp at its next step and one whose last step did so at its `expect` sub, each with the guard's
# line; an inner driver started with XDG_STATE_HOME, XDG_CACHE_HOME, CLAUDE_PLUGIN_DATA, the
# folder options, STORE_TEST_TRACE and GIT_DIR at stand-ins runs a case that writes watch logs
# (X-hooks) and one whose environment holds none of them and whose fixture git commits land in
# its own repo (_env), and nothing lands in the stand-ins (the stand-in repo keeps its one
# commit); an inner driver whose TMPDIR lies in a stand-in real home's .local/state, is relative,
# or goes through a link into that folder and `..` ends at start, exit 2, with the guard's line,
# and writes nothing there.
my (@bad, @tried, $want_rows);
my $HERE = do { (my $d = __FILE__) =~ s{/[^/]*\z}{}; $d };
my $DRIVER = sub { return "$T::REPO/tests/helper/cases/watch/_driver/run-watch.pl" };
{
    steps => [
        { call => 'code', code => sub {
            my $v = shift;
            my $tmp = $v->{TMP};
            push @bad, "case HOME is " . ($ENV{HOME} // '(unset)') . ", want the case's $v->{HOME}" unless ($ENV{HOME} // '') eq $v->{HOME};
            push @bad, "CLAUDE_CONFIG_DIR is set in the case ($ENV{CLAUDE_CONFIG_DIR})" if defined $ENV{CLAUDE_CONFIG_DIR};
            push @bad, "the driver's environment holds $_ (the driver starts from a fresh one)"
                for sort grep { /\A(?:CLAUDE|XDG_|GIT_)/ || (/\ASTORE_/ && !/\ASTORE_TEST_(?:MODE|NOW)\z/) } keys %ENV;
            my $dh = $v->{DRIVER_HOME};
            push @bad, "the driver's own HOME '$dh' is empty, a real home or not under a temp folder"
                unless $dh ne '' && homeguard::under_temp($dh) && !homeguard::real_home($dh);
            # the real ones, read by init (no link is made to them): the account's home, its .claude
            # and its .local/state
            my $acct = $homeguard::REAL{account} // die "no account home\n";
            push @bad, "the guard does not hold the account's home $acct as a real home" unless homeguard::real_home($acct);
            push @bad, "the guard does not hold $acct/.claude as a real config folder" unless homeguard::real_config("$acct/.claude");
            push @bad, "the guard does not hold $acct/.local/state as a real state folder" unless homeguard::real_state("$acct/.local/state");
            my $true = -x '/usr/bin/true' ? '/usr/bin/true' : '/bin/true';
            my $t = homeguard::self_rows($tmp, $v->{HOME});
            local %homeguard::REAL = %{ $t->{real} };
            # the driver works in $tmp here, so a relative HOME read against it lies under temp:
            # only the absolute rule refuses it
            my $back = Cwd::getcwd();
            chdir($tmp) or die "chdir $tmp: $!\n";
            for my $row (@{ $t->{rows} }) {
                local @homeguard::TEMP_ROOTS = $row->{temp} ? @{ $row->{temp} } : @homeguard::TEMP_ROOTS;
                local $homeguard::WALK_MAX = $row->{budget}{max} // $homeguard::WALK_MAX;
                local $homeguard::WALK_DEPTH = $row->{budget}{depth} // $homeguard::WALK_DEPTH;
                local %ENV = %ENV;
                my $over = $row->{env};
                for my $k (keys %$over) { if (defined $over->{$k}) { $ENV{$k} = $over->{$k} } else { delete $ENV{$k} } }
                push @tried, $row->{what};
                my $r = eval { main::run_child([$true], '', 'cli true') };
                my $cerr = $@;
                my $g = eval { T::_git($tmp, '--version'); 1 };
                my $gerr = $@;
                push @bad, "$row->{what}: the cli child exited $r->{exit}" if $row->{ok} && $r && $r->{exit} != 0;
                push @bad, homeguard::self_row_errs($row, ['cli child', $r ? 1 : 0, $cerr], ['git child', $g ? 1 : 0, $gerr]);
            }
            chdir($back) or die "chdir $back: $!\n";
            chmod(0700, @{ $t->{restore} });
        } },
        # the per-step and expect checks: a driver run over _step, whose first step leaves HOME
        # outside the temp folders, fails that case at its second step, and over _expect, whose last
        # step does so, fails that case before its expect sub runs, each with the guard's line
        { call => 'code', code => sub {
            push @tried, 'a step after HOME left temp', 'an expect sub after HOME left temp';
            my $r = main::run_child([$^X, $DRIVER->(), "$HERE/_step", "$HERE/_expect"], '', 'inner driver');
            push @bad, "the inner driver run exited $r->{exit}, want 1: $r->{stdout}$r->{stderr}" unless $r->{exit} == 1;
            push @bad, "the inner driver run has no HOME-GUARD line for the second step: $r->{stdout}$r->{stderr}"
                unless $r->{stdout} =~ m{^not ok - _step\n#   died: HOME-GUARD: step code: HOME /nonexistent-home-guard is not under a temp folder; not started$}m;
            push @bad, "the inner driver run has no HOME-GUARD line for the expect sub: $r->{stdout}$r->{stderr}"
                unless $r->{stdout} =~ m{^not ok - _expect\n#   died: HOME-GUARD: expect: HOME /nonexistent-home-guard is not under a temp folder; not started$}m;
        } },
        # a driver started with the state folders, the helper's trace file and GIT_DIR at
        # stand-ins: its fresh environment passes none of them on, so X-hooks (cli hook calls that
        # write dispatch records and watch logs under the default handoff root) passes, _env (its
        # environment, fixture git commits in its own repo) passes, nothing lands in the stand-in
        # folders and the stand-in repo keeps its one commit
        { call => 'code', code => sub {
            my $v = shift;
            my %sf = map { ($_ => "$v->{TMP}/standin-state/" . lc) } qw(XDG_STATE_HOME XDG_CACHE_HOME CLAUDE_PLUGIN_DATA
                                                                         CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT CLAUDE_PLUGIN_OPTION_LOG_DIR);
            watch::io::mkdir_p($_) for values %sf;
            my $trace = "$v->{TMP}/standin-state/trace";
            watch::io::mkdir_p($trace);
            my $repo = "$v->{TMP}/standin-repo";
            watch::io::mkdir_p($repo);
            T::_git($repo, 'init', '-q');
            T::_git($repo, 'commit', '-q', '--allow-empty', '-m', 'fixture');
            push @tried, 'a driver started with the state folders, STORE_TEST_TRACE and GIT_DIR at stand-ins';
            my $r = do {
                local %ENV = (%ENV, %sf, STORE_TEST_TRACE => "$trace/trace.log", GIT_DIR => "$repo/.git");
                main::run_child([$^X, $DRIVER->(), "$HERE/../X-hooks", "$HERE/_env"], '', 'inner driver');
            };
            push @bad, "the inner driver run with stand-in state folders exited $r->{exit}, want 0: $r->{stdout}$r->{stderr}" unless $r->{exit} == 0;
            for my $k (sort(keys %sf), 'STORE_TEST_TRACE') {
                my @q = ($sf{$k} // $trace);
                while (defined(my $d = shift @q)) {
                    for my $n (watch::io::list_dir($d)) {
                        my $p = "$d/$n";
                        if (-d $p && !-l $p) { push @q, $p } else { push @bad, "$p landed in the stand-in $k" }
                    }
                }
            }
            my $c = main::run_child(['git', '-C', $repo, 'rev-list', '--count', '--all'], '', 'git rev-list');
            push @bad, "the stand-in repo holds $c->{stdout} commits, want its one (a fixture commit landed there)" unless $c->{stdout} eq "1\n";
        } },
        # a driver whose TMPDIR lies in a real state folder (a stand-in HOME's .local/state) ends
        # at start, before it makes its temp folders there
        { call => 'code', code => sub {
            my $v = shift;
            my $fh = "$v->{TMP}/standin-tmpdir";
            my $td = "$fh/.local/state/t";
            watch::io::mkdir_p($td);
            push @tried, 'a driver whose TMPDIR lies in a real state folder';
            my $r = do {
                local %ENV = (%ENV, HOME => $fh, TMPDIR => $td);
                main::run_child([$^X, $DRIVER->(), "$HERE/../X-hooks"], '', 'inner driver');
            };
            push @bad, "the inner driver run with TMPDIR in a real state folder exited $r->{exit}, want 2: $r->{stdout}$r->{stderr}" unless $r->{exit} == 2;
            push @bad, "the inner driver run with TMPDIR in a real state folder has no HOME-GUARD line: $r->{stdout}$r->{stderr}"
                unless $r->{stderr} =~ m{\AHOME-GUARD: TMPDIR \S+/standin-tmpdir/\.local/state/t is in a real state folder; nothing written\n\z};
            my @q = ("$fh/.local/state");
            while (defined(my $d = shift @q)) {
                for my $n (watch::io::list_dir($d)) {
                    my $p = "$d/$n";
                    if (-d $p && !-l $p) { push @q, $p; push @bad, "$p landed in the stand-in real state folder" if $p ne $td } else { push @bad, "$p landed in the stand-in real state folder" }
                }
            }
        } },
        # a driver whose TMPDIR is relative, or goes through a link into a real state folder (a
        # stand-in HOME's .local/state) and `..`, ends at start, before it makes its temp folders
        { call => 'code', code => sub {
            my $v = shift;
            my $fh = "$v->{TMP}/standin-tmpdir2";
            watch::io::mkdir_p("$fh/.local/state/t");
            symlink("$fh/.local/state/t", "$fh/L") or die "symlink $fh/L: $!\n";
            for my $c (['home-guard-rel/t', qr{\AHOME-GUARD: TMPDIR home-guard-rel/t is not absolute \(it is read against the runner's folder\); nothing written\n\z}],
                       ["$fh/L/..", qr{\AHOME-GUARD: TMPDIR \S+/standin-tmpdir2/L/\.\. has a \.\. part \(applied after links\); nothing written\n\z}]) {
                my ($td, $want) = @$c;
                push @tried, "a driver whose TMPDIR is $td";
                my $r = do {
                    local %ENV = (%ENV, HOME => $fh, TMPDIR => $td);
                    main::run_child([$^X, $DRIVER->(), "$HERE/../X-hooks"], '', 'inner driver');
                };
                push @bad, "the inner driver run with TMPDIR $td exited $r->{exit}, want 2: $r->{stdout}$r->{stderr}" unless $r->{exit} == 2;
                push @bad, "the inner driver run with TMPDIR $td has no HOME-GUARD line: $r->{stdout}$r->{stderr}" unless $r->{stderr} =~ $want;
            }
            my @q = ("$fh/.local/state");
            while (defined(my $d = shift @q)) {
                for my $n (watch::io::list_dir($d)) {
                    my $p = "$d/$n";
                    if (-d $p && !-l $p) { push @q, $p; push @bad, "$p landed in the stand-in real state folder" if $n ne 't' } else { push @bad, "$p landed in the stand-in real state folder" }
                }
            }
        } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(@tried >= 67, 'home guard: ' . scalar(@tried) . ' environments tried, want at least 67');
        $E->ok(0, $_) for @bad;
    },
};

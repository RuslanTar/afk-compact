# AT-RN-07 (HOME-GUARD, 0.1.2; AT-RN-06 is the core case runner's): the watch driver runs in a
# fresh environment with a temp HOME (no CLAUDE_CONFIG_DIR, CLAUDE* or XDG_* name of the
# caller's), each case with its own $HOME, and the real homes, config folder and state folders the
# guard read at start are the owner's. With stand-ins for those (homeguard::self_rows: a real
# HOME, an account home, a config folder and state folders given, all under $TMP, so no link into
# the real home or ~/.claude is made) it refuses, before the child starts, a `cli` child
# (run_child) and a fixture git child (T::_git) in every row of the guard's table (the same table
# as AT-RN-06: a real home or a link to it or another case of its name, no, an empty, a relative
# HOME or one outside temp, `..` through a link, a CLAUDE_CONFIG_DIR at a real config folder,
# relative or outside temp, a temp HOME whose .claude or settings.json links to the real one,
# whose .claude is a dangling link or links outside temp, TMPDIR at the account's home or another
# case of it, a state folder outside temp, relative, through `..` or in a real config or state
# folder). The `cli` child is `true` and the git child `git --version`, so a guard that lets one
# through starts nothing that reads or writes a home. The rows that pass start both. An inner
# driver run fails a case whose step moved HOME outside temp at its next step and one whose last
# step did so at its `expect` sub, each with the guard's line; an inner driver started with
# XDG_STATE_HOME, XDG_CACHE_HOME, CLAUDE_PLUGIN_DATA and the folder options at stand-in folders
# runs a case that writes watch logs (X-hooks) and nothing lands there.
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
            push @bad, "the driver's environment holds $_ (the driver starts from a fresh one)" for sort grep { /\A(?:CLAUDE|XDG_)/ } keys %ENV;
            my $dh = $v->{DRIVER_HOME};
            push @bad, "the driver's own HOME '$dh' is empty, a real home or not under a temp folder"
                unless $dh ne '' && homeguard::under_temp($dh) && !homeguard::real_home($dh);
            # the real ones, read by init (no link is made to them): the account's home and its .claude
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
        # a driver started with the state folders at stand-ins: its fresh environment passes none
        # of them on, so X-hooks (cli hook calls that write dispatch records and watch logs under
        # the default handoff root) passes and nothing lands in them
        { call => 'code', code => sub {
            my $v = shift;
            my %sf = map { ($_ => "$v->{TMP}/standin-state/" . lc) } qw(XDG_STATE_HOME XDG_CACHE_HOME CLAUDE_PLUGIN_DATA
                                                                         CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT CLAUDE_PLUGIN_OPTION_LOG_DIR);
            watch::io::mkdir_p($_) for values %sf;
            push @tried, 'a driver started with the state folders at stand-ins';
            my $r = do {
                local %ENV = (%ENV, %sf);
                main::run_child([$^X, $DRIVER->(), "$HERE/../X-hooks"], '', 'inner driver');
            };
            push @bad, "the inner driver run with stand-in state folders exited $r->{exit}, want 0: $r->{stdout}$r->{stderr}" unless $r->{exit} == 0;
            for my $k (sort keys %sf) {
                my @q = ($sf{$k});
                while (defined(my $d = shift @q)) {
                    for my $n (watch::io::list_dir($d)) {
                        my $p = "$d/$n";
                        if (-d $p && !-l $p) { push @q, $p } else { push @bad, "$p landed in the stand-in $k" }
                    }
                }
            }
        } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(@tried >= 35, 'home guard: ' . scalar(@tried) . ' environments tried, want at least 35');
        $E->ok(0, $_) for @bad;
    },
};

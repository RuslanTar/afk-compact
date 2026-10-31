# AT-RN-07 (HOME-GUARD, 0.1.2; AT-RN-06 is the core case runner's): the watch driver runs with a
# temp HOME and no CLAUDE_CONFIG_DIR, each case with its own $HOME, and refuses, before the
# child starts, a `cli` child (run_child) and a fixture git child (T::_git) whose environment
# could reach the real home or config folder: the real HOME, the account's home, a link to it,
# no HOME, an empty HOME, a HOME outside the temp folders, a CLAUDE_CONFIG_DIR at the real
# ~/.claude, a relative one, one outside the temp folders; with TMPDIR at the account's home, a
# CLAUDE_CONFIG_DIR at its .claude. The `cli` child is `true` and the git child `git --version`,
# so a guard that lets one through starts nothing that reads or writes a home. A temp HOME, with
# or without a CLAUDE_CONFIG_DIR under it, starts both.
my (@bad, @tried);
{
    steps => [
        { call => 'code', code => sub {
            my $v = shift;
            my $tmp = $v->{TMP};
            push @bad, "case HOME is " . ($ENV{HOME} // '(unset)') . ", want the case's $v->{HOME}" unless ($ENV{HOME} // '') eq $v->{HOME};
            push @bad, "CLAUDE_CONFIG_DIR is set in the case ($ENV{CLAUDE_CONFIG_DIR})" if defined $ENV{CLAUDE_CONFIG_DIR};
            my $dh = $v->{DRIVER_HOME};
            push @bad, "the driver's own HOME '$dh' is not a temp folder"
                unless $dh ne '' && homeguard::under_temp($dh) && !$homeguard::REAL_HOMES{ util::real_path($dh) // '' };
            my $acct = $homeguard::ACCOUNT_HOME // die "no account home\n";
            symlink($acct, "$tmp/link-home") or die "symlink: $!\n" unless -l "$tmp/link-home";
            my $true = -x '/usr/bin/true' ? '/usr/bin/true' : '/bin/true';
            my $th = $v->{HOME};
            my @cases = (["the account's home", { HOME => $acct }], ['a link to the account home', { HOME => "$tmp/link-home" }],
                         ['no HOME', { HOME => undef }], ['an empty HOME', { HOME => '' }],
                         ['a HOME outside the temp folders', { HOME => '/nonexistent-home-guard' }],
                         ['CLAUDE_CONFIG_DIR at the real ~/.claude', { CLAUDE_CONFIG_DIR => "$acct/.claude" }],
                         ['a relative CLAUDE_CONFIG_DIR', { CLAUDE_CONFIG_DIR => 'cfg' }],
                         ['a CLAUDE_CONFIG_DIR outside the temp folders', { CLAUDE_CONFIG_DIR => '/nonexistent-config-guard' }]);
            my $rh = $homeguard::REAL_HOME;
            unshift @cases, ['the real HOME', { HOME => $rh }] if defined $rh && $rh =~ m{\A/} && $homeguard::REAL_HOMES{ util::real_path($rh) // '' };
            push @cases, map { [@$_, 'ok'] } (['a temp HOME', {}], ['a CLAUDE_CONFIG_DIR under the temp HOME', { CLAUDE_CONFIG_DIR => '~/.claude' }],
                                              ['an absolute CLAUDE_CONFIG_DIR under the temp HOME', { CLAUDE_CONFIG_DIR => "$th/.claude" }]);
            for my $c (@cases) {
                my ($what, $over, $ok) = @$c;
                local %ENV = %ENV;
                for my $k (keys %$over) { if (defined $over->{$k}) { $ENV{$k} = $over->{$k} } else { delete $ENV{$k} } }
                push @tried, $what;
                my $r = eval { main::run_child([$true], '', 'cli true') };
                my $cerr = $@;
                my $g = eval { T::_git($tmp, '--version'); 1 };
                my $gerr = $@;
                if ($ok) {
                    push @bad, "$what: the cli child was refused: $cerr" if $cerr;
                    push @bad, "$what: the cli child exited $r->{exit}" if $r && $r->{exit} != 0;
                    push @bad, "$what: the git child was refused: $gerr" if !$g;
                    next;
                }
                push @bad, "$what: the cli child started (exit $r->{exit}), want HOME-GUARD" if $r;
                push @bad, "$what: the cli child died with '$cerr', want HOME-GUARD" if !$r && $cerr !~ /\AHOME-GUARD: /;
                push @bad, "$what: the git child started, want HOME-GUARD" if $g;
                push @bad, "$what: the git child died with '$gerr', want HOME-GUARD" if !$g && $gerr !~ /\AHOME-GUARD: /;
            }
            # a driver started with TMPDIR=$HOME: the real ~/.claude lies under a "temp" folder and
            # is still refused
            {
                local @homeguard::TEMP_ROOTS = (util::real_path($acct));
                local %ENV = (%ENV, HOME => "$acct/home-guard-none", CLAUDE_CONFIG_DIR => "$acct/.claude");
                push @tried, 'TMPDIR the account home';
                my $r = eval { main::run_child([$true], '', 'cli true') };
                my $err = $@;
                push @bad, "TMPDIR the account's home: CLAUDE_CONFIG_DIR at its .claude started the cli child" if $r;
                push @bad, "TMPDIR the account's home: died with '$err', want the real config folder"
                    if !$r && $err !~ /\AHOME-GUARD: .* is the real config folder; /;
            }
        } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(@tried >= 12, 'home guard: ' . scalar(@tried) . ' environments tried, want at least 12');
        $E->ok(0, $_) for @bad;
    },
};

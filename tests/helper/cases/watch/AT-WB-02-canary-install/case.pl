# AT-WB-02 (and the identity half of AT-WB-03) on WP-fix's canary install (W-BETA B.3, B.4;
# tests/fixtures/setups/wb-canary-install.json; needs/fix-to-watch.md 1, 7). The recipe plants
# a unique canary in every place B.3 names: the account (USER/LOGNAME, the git remote owner),
# the host (a `hostname` PATH stub, which B.3's `hostname -s` reads), the repo and its
# repo_roots entry, the branch, the ticket, the topic bucket, a summary copy, a handoff, a
# jobs command, an evidence path, a queue question, the config paths and patterns, and a
# corpus secret in a classic row; $HOME sits in row paths. `report` runs as the recipe's
# `invoke` says (argv, cwd, env, PATH prefix, clock). Every `expect.canaries` value, every
# `expect.also_absent` value ($HOME expanded, the corpus secret) has 0 hits in the unpacked
# zip and in its bytes; the watcher's identity list for this install holds every
# `expect.identity_list` entry; the zip verifies. Skipped until the fixture is on the branch.
# $WATCH is the install's effective watch folder: the recipe's settings set `log_dir`, and a
# safe `log_dir` is the watch folder (lib/rc.pm), so `$WATCH/...` files are planted under the
# `log_dir` value, where `report` reads them (watch-to-fix.md W2F-1).
my $RECIPE = 'setups/wb-canary-install.json';
my $rc = T::fixture_json($RECIPE);
return { skip => "needs tests/fixtures/$RECIPE (WP-fix FIX-06)" } unless $rc;
my %got;
{
    allow_canary => 1,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v0) = @_;
              my ($sw0) = grep { ($_->{write} // q()) =~ m{/\.claude/settings\.json\z} } @{ $rc->{setup} };
              my ($o0) = values %{ $sw0 ? $sw0->{json}{pluginConfigs} : {} };
              my $ld = $o0 && $o0->{options}{log_dir};
              my $v = { %$v0, (defined $ld && length $ld ? (WATCH => T::subst($ld, $v0)) : ()) };
              T::run_setup($rc->{setup}, $v);
              my $inv = T::subst_deep($rc->{invoke}, $v);
              my $l = main::cli_launcher();
              my %env = (%{ $inv->{env} || {} }, STORE_TEST_NOW => '2026-10-21T14:05:12+03:00');
              $env{PATH} = join(':', @{ $inv->{path_prepend} || [] }, $ENV{PATH});
              local @ENV{ keys %env } = values %env;
              # HOME-GUARD: the recipe's env is laid over the checked one; `report` and `report verify`
              # below start with it
              homeguard::check(\%ENV, 'report');
              my $cwd = Cwd::getcwd();
              chdir($inv->{cwd} // $v->{TMP}) or die "chdir: $!";
              my $q = join(' ', map { "'" . s/'/'\\''/gr . "'" } ($l, @{ $inv->{argv} }));
              $got{out} = `$q 2>&1 < /dev/null`;
              $got{exit} = $? >> 8;
              my @z = T::zips_in("$v->{TMP}/out");
              $got{zips} = \@z;
              if (@z == 1) {
                  $got{raw} = watch::io::slurp($z[0]);
                  $got{e} = T::zip_entries($z[0]);
                  $got{verify} = `'$l' report verify --zip '$z[0]' 2>&1`;
                  $got{verify_exit} = $? >> 8;
              }
              # The B.3 list as `report` builds it for this install: the repo_roots entry from
              # the recipe's settings file (the staged launcher reads it; in-process the repo's
              # plugin/ has no consent mark), git on, the same PATH, USER and LOGNAME.
              require watch::export;
              my ($sw) = grep { ($_->{write} // q()) =~ m{/\.claude/settings\.json\z} } @{ $rc->{setup} };
              my $opts = $sw ? $sw->{json}{pluginConfigs} : {};
              my ($o) = values %{ T::subst_deep($opts, $v) };
              my $ctx = watch::ctx::init({ sid => 'unknown', watch => $v->{WATCH}, root => $v->{ROOT}, plugin_root => $v->{PLUGIN},
                                           settings => {}, now => $T::BASE + 100 });
              $ctx->{settings}{repo_roots_list} = [ split /;/, $o->{options}{repo_roots} ];
              $got{list} = watch::export::identity_list($ctx);
              chdir $cwd;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $x = $rc->{expect};
        $E->is($got{exit}, 0, "report exit 0 ($got{out})");
        $E->is(scalar @{ $got{zips} || [] }, 1, 'one zip') or return;
        $E->is($got{verify_exit}, 0, "the zip verifies ($got{verify})");
        my $all = join("\n", map { $_->{data} // '' } values %{ $got{e} });
        my %v = (HOME => $E->var('HOME'), TMP => $E->var('TMP'), ROOT => $E->var('ROOT'), WATCH => $E->var('WATCH'));
        for my $k (sort keys %{ $x->{canaries} }) {
            my $c = $x->{canaries}{$k};
            $E->ok((index(lc $all, lc $c) < 0 ? 1 : 0), "canary $k ($c): 0 hits in the bundle");
            $E->ok((index($got{raw}, $c) < 0 ? 1 : 0), "canary $k: 0 hits in the zip bytes");
        }
        for my $a (@{ $x->{also_absent} || [] }) {
            my $s = T::subst($a, \%v);
            $E->ok((index($all, $s) < 0 && index($got{raw}, $s) < 0 ? 1 : 0), "also absent: $a");
        }
        my %l = map { lc($_) => 1 } @{ $got{list} || [] };
        for my $i (@{ $x->{identity_list} || [] }) {
            my $s = T::subst($i, \%v);
            $E->ok(($l{ lc $s } ? 1 : 0), "identity list holds $i");
        }
        my @rows = grep { m{\Arows/} } keys %{ $got{e} };
        my $m = eval { watch::json::decode($got{e}{'manifest.json'}{data}) } || {};
        my $shipped = @rows + @{ $m->{withheld} || [] };
        $E->ok(($shipped >= 1 ? 1 : 0), 'the session is in the bundle or named as withheld');
    },
};

# AT-WB-06 (D-8; W-BETA B.6; BUILD-ROUND-9 WCH-09): after 3 reports every file that was under
# <watch> before is byte-identical (mode too); the only new files are the zips, the salt
# (32 bytes, 0600) and the install id (0600). Default out folder: ~/Downloads when it is a
# writable folder outside a git work tree; inside a work tree (here a home repository that
# ignores .claude/ and .local/state/<plugin>/), or missing, the fallback is <watch>/reports/. An --out folder that does
# not exist: exit 73, nothing written. Usage errors (an unknown flag, a value given to the
# bare `--with-summaries` flag (RS-2: the user's yes in that run is the only way on), a bad
# --since) exit 64.
my %got;
{
    needs => ['cmd:git'],
    needs_note => 'the home work tree must ignore .claude/ and .local/state/<plugin>/ (git check-ignore), or the report is refused',
    allow_canary => 1,
    files => T::beta_install(),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{HOME}/Downloads");
              $got{w0} = T::tree($v->{WATCH});
          } },
        { call => 'cli', at => 3600, argv => [ 'report' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        # a dotfiles repository that ignores .claude/ and .local/state/<plugin>/: Downloads is in a work tree, the handoff
        # root is git-ignored and ok (a not-ignored root would refuse the report: WATCH §6.1)
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\n";
              close $fh;
          } },
        { call => 'cli', at => 3601, argv => [ 'report' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'cli', at => 3602, argv => [ 'report', '--since', '1d' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'cli', at => 3603, argv => [ 'report', '--out', '$TMP/nope' ], env => { STORE_TEST_NO_GIT => '1' },
          exit => 73, stdout_re => qr/\AREFUSED: output folder not writable$/ },
        { call => 'cli', argv => [ 'report', '--bogus' ], exit => 64, any_stdout => 1 },
        { call => 'cli', argv => [ 'report', '--with-summaries=yes' ], exit => 64, any_stdout => 1 },
        { call => 'cli', argv => [ 'report', '--since', 'yesterday' ], exit => 64, any_stdout => 1 },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{w1} = T::tree($v->{WATCH});
              $got{dl} = [ T::zips_in("$v->{HOME}/Downloads") ];
              $got{fb} = [ T::zips_in("$v->{WATCH}/reports") ];
              $got{salt} = -s "$v->{WATCH}/export-salt";
              $got{salt_mode} = (stat "$v->{WATCH}/export-salt")[2] & 07777;
              $got{id_mode} = (stat "$v->{WATCH}/install-id")[2] & 07777;
              $got{nope} = -e "$v->{TMP}/nope" ? 1 : 0;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my ($w0, $w1) = @got{qw(w0 w1)};
        for my $f (sort keys %$w0) { $E->is($w1->{$f}, $w0->{$f}, "unchanged: $f") }
        my @new = sort grep { !exists $w0->{$_} } keys %$w1;
        $E->is(join(',', grep { !m{\Areports/[^/]+\.zip\z} } @new), 'export-salt,install-id', 'new under <watch>: salt, id, zips only');
        $E->is(scalar @{ $got{dl} }, 1, 'first report: ~/Downloads (outside a work tree)');
        $E->is(scalar @{ $got{fb} }, 2, 'with ~/.git above Downloads: the <watch>/reports fallback');
        $E->is($got{salt}, 32, 'salt is 32 bytes');
        $E->is(sprintf('%o', $got{salt_mode} // 0), '600', 'salt 0600');
        $E->is(sprintf('%o', $got{id_mode} // 0), '600', 'install id 0600');
        $E->is($got{nope}, 0, 'a missing --out folder is not created');
        my @o = $E->outputs;
        my ($id1) = $o[0]{stdout} =~ /-([0-9a-f]{8})\.zip /;
        my ($id2) = $o[1]{stdout} =~ /-([0-9a-f]{8})\.zip /;
        $E->ok((defined $id1 && defined $id2 && $id1 eq $id2 ? 1 : 0), 'one install id across reports');
    },
};

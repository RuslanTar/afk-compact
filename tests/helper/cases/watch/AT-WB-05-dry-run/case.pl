# AT-WB-05 (Dev-6): `report --dry-run` creates no file at all.
# The trees of <watch> and of the out folder are equal before and after; no salt and no
# install id are created; the REPORT line says nothing was written and no REVEAL or COPY
# line is printed. The default out folder is not created either.
my %got;
{
    allow_canary => 1,
    files => T::beta_install(),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{TMP}/out");
              $got{w0} = T::tree($v->{WATCH});
              $got{o0} = T::tree("$v->{TMP}/out");
              $got{h0} = T::tree($v->{HOME});
          } },
        { call => 'cli', argv => [ 'report', '--dry-run', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/\AREPORT \S+\.zip \S+ \S+ \(dry run: nothing written\)$/m },
        { call => 'cli', argv => [ 'report', '--dry-run' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/\(dry run: nothing written\)/ },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{w1} = T::tree($v->{WATCH});
              $got{o1} = T::tree("$v->{TMP}/out");
              $got{h1} = T::tree($v->{HOME});
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $cmp = sub { my ($a, $b) = @_; return join("\n", map { "$_=$a->{$_}" } sort keys %$a) eq join("\n", map { "$_=$b->{$_}" } sort keys %$b) ? 1 : 0 };
        $E->ok($cmp->($got{w0}, $got{w1}), 'the watch tree is unchanged');
        $E->ok($cmp->($got{o0}, $got{o1}), 'the out folder is unchanged');
        $E->ok($cmp->($got{h0}, $got{h1}), 'nothing under HOME changed (no reports folder, no salt)');
        $E->ok((!exists $got{w1}{'export-salt'} && !exists $got{w1}{'install-id'} ? 1 : 0), 'no salt, no install id');
        my ($a, $b) = $E->outputs;
        $E->ok(($a->{stdout} !~ /^(?:REVEAL|COPY):/m ? 1 : 0), 'no REVEAL or COPY line in a dry run');
        $E->ok(($a->{stdout} =~ /-dryrun00\.zip /m ? 1 : 0), 'the would-be name has no install id');
    },
};

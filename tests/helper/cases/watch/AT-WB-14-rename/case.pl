# AT-WB-14: rename safety. `report verify` accepts a bundle
# whose `plugin` (and `schema`) is the old name or the new name, as long as the schema is
# `<plugin>-report/1`; a schema that does not match its own plugin name fails.
my %got;
{
    allow_canary => 1,
    files => T::beta_install(),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::bundle;
              my ($z) = T::zips_in("$v->{TMP}/out");
              my $e = T::zip_entries($z);
              my $l = main::cli_launcher();
              my $remake = sub {
                  my ($plugin, $schema, $file) = @_;
                  my $m = watch::json::decode($e->{'manifest.json'}{data});
                  $m->{plugin} = $plugin;
                  $m->{schema} = $schema;
                  my @ent = map { [ $_, ($_ eq 'manifest.json' ? watch::json::encode($m) . "\n" : $e->{$_}{data}) ] }
                            ('README.txt', 'manifest.json', grep { $_ ne 'README.txt' && $_ ne 'manifest.json' } sort keys %$e);
                  main::write_file("$v->{TMP}/$file", watch::bundle::zip(\@ent, $T::BASE), 0600);
                  my $o = `'$l' report verify --zip '$v->{TMP}/$file' 2>&1`;
                  return [ $? >> 8, $o ];
              };
              $got{old} = $remake->('storewatch', 'storewatch-report/1', 'old.zip');
              $got{new} = $remake->('newname', 'newname-report/1', 'new.zip');
              $got{mix} = $remake->('newname', 'storewatch-report/1', 'mix.zip');
              $got{v2} = $remake->('newname', 'newname-report/2', 'v2.zip');
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{old}[0], 0, "old name verifies ($got{old}[1])");
        $E->is($got{new}[0], 0, "new name verifies ($got{new}[1])");
        $E->is($got{mix}[0], 1, 'a schema of another name fails');
        $E->is($got{v2}[0], 1, 'an unknown schema version fails');
    },
};

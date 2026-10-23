# E-W-1 and E-W-3 (provisional; needs/watch-escalations.md; BUILD-ROUND-9 WCH-09):
# (1) repo folders named like the bundle's own vocabulary (the brand, `shadow`, `main`) are no
# identity hit: the report is written and nothing is withheld for them, while a real hole (a
# `word` field holding another repo folder's name) is still withheld;
# (2) the secret scan reads a JSON file's values, so the schema's own field `key`
# (`"key":"soft_max"`) is no WARN key-value hit, and the bundle still verifies.
my $files = T::beta_install();
push @$files,
    { path => '$ROOT/' . $T::BRAND . '/general/x.md', text => "x\n" },
    { path => '$ROOT/shadow/main/x.md', text => "x\n" },
    { path => '$WATCH/0e0e0e0e-1111-4111-8111-111111111111.jsonl',
      jsonl => [ T::row('config_clamped', 60, key => 'soft_max', configured => 600000, effective => 180000),
                 T::row('config_invalid', 61, key => 'handoff_turn') ] },
    { path => '$WATCH/0f0f0f0f-2222-4222-8222-222222222222.classic.jsonl',
      jsonl => [ T::row('copy_failed', 62, writer => 'classic', nonce => 'f0f00005', reason => 'canaryrepoalpha') ] };
my %got;
{
    allow_canary => 1,
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z) = T::zips_in("$v->{TMP}/out");
              $got{e} = $z ? T::zip_entries($z) : {};
              my $l = main::cli_launcher();
              $got{verify} = $z ? `'$l' report verify --zip '$z' 2>&1` : '';
              $got{verify_exit} = $? >> 8;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $e = $got{e};
        my $m = eval { watch::json::decode($e->{'manifest.json'}{data}) } || {};
        my @w = @{ $m->{withheld} || [] };
        $E->is(scalar @w, 1, 'only the real hole is withheld');
        $E->is($w[0]{reason}, 'identity', 'and it is the identity hole') if @w;
        $E->is(scalar(grep { m{\Arows/} } keys %$e), 2, 'the other two sessions ship (the key fields are no secret hit)');
        my $all = join("\n", map { $_->{data} // '' } grep { $_->{name} =~ m{\Arows/} } values %$e);
        $E->ok((index($all, '"key":"soft_max"') >= 0 ? 1 : 0), 'the config_clamped row is in the bundle');
        $E->is($got{verify_exit}, 0, "the bundle verifies ($got{verify})");
    },
};

# AT-WB-04 (W-BETA B.4; BUILD-ROUND-9 WCH-09): a secret-shaped value that passes its field
# class (a lowercase Slack-token shape in a `word` field) is caught by the secret scan of the
# staged file: the file is withheld and the manifest records the rule id only, never the
# value. The WITHHELD line names the rule.
my $tok = 'xoxb-1234567890abcdef';
my %got;
{
    allow_canary => 1,
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('copy_failed', 10, writer => 'classic', nonce => 'f0f00004', reason => $tok),
                            T::row('copy', 11, writer => 'classic', nonce => 'f0f00004', result => 'saved', slot => 'main') ] },
               { path => '$WATCH/0e0e0e0e-1111-4111-8111-111111111111.jsonl',
                 jsonl => [ T::row('continue', 12, result => 'submitted', continues_last_hour => 1) ] } ],
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^WITHHELD rows\/[0-9a-f]{12}\.jsonl \(secret: slack-token\)$/m },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z) = T::zips_in("$v->{TMP}/out");
              $got{e} = $z ? T::zip_entries($z) : {};
              $got{raw} = $z ? watch::io::slurp($z) : '';
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $e = $got{e};
        my $all = join("\n", map { $_->{data} // '' } values %$e);
        $E->ok((index($all, $tok) < 0 && index($got{raw}, $tok) < 0 ? 1 : 0), 'the token is in no shipped file');
        my $m = eval { watch::json::decode($e->{'manifest.json'}{data}) } || {};
        my @w = @{ $m->{withheld} || [] };
        $E->is(scalar @w, 1, 'one withheld entry');
        $E->is($w[0]{reason}, 'secret', 'reason secret') if @w;
        $E->is(join(',', @{ $w[0]{rules} || [] }), 'slack-token', 'rule ids only') if @w;
        $E->is(scalar(grep { m{\Arows/} } keys %$e), 1, 'the clean session still ships');
    },
};

# AT-WB-03: the identity scan fails closed. A schema
# hole lets an identifying string through (a `word`-class field holding the repo folder's
# name, a basename under handoff_root): that staged file is withheld, the manifest names it
# with reason `identity` and a count (never the string), the WITHHELD line prints, the exit
# is 0, and one `report_withheld {reason, file_kind}` row is written. The other files ship.
my $files = T::beta_install();
push @$files, { path => '$WATCH/0e0e0e0e-1111-4111-8111-111111111111.classic.jsonl',
                jsonl => [ T::row('copy_failed', 60, writer => 'classic', nonce => 'f0f00003', reason => 'canaryrepoalpha') ] };
my %got;
{
    allow_canary => 1,
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^WITHHELD rows\/[0-9a-f]{12}\.jsonl \(identity; please tell the developer\)$/m },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z) = T::zips_in("$v->{TMP}/out");
              $got{e} = $z ? T::zip_entries($z) : {};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my ($out) = $E->outputs;
        $E->is($out->{exit}, 0, 'exit 0 with a withheld file');
        my $e = $got{e};
        my @rows = grep { m{\Arows/} } keys %$e;
        $E->is(scalar @rows, 1, 'the other session`s rows still ship');
        my $all = join("\n", map { $_->{data} // '' } values %$e);
        $E->ok((index($all, 'canaryrepoalpha') < 0 ? 1 : 0), 'the identifying string is in no shipped file');
        my $m = eval { watch::json::decode($e->{'manifest.json'}{data}) } || {};
        my @w = @{ $m->{withheld} || [] };
        $E->is(scalar @w, 1, 'one withheld entry');
        $E->is($w[0]{reason}, 'identity', 'reason identity') if @w;
        $E->ok(($w[0]{file} =~ m{\Arows/[0-9a-f]{12}\.jsonl\z} ? 1 : 0), 'the withheld file is named') if @w;
        $E->ok((($w[0]{count} // 0) >= 1 ? 1 : 0), 'a hit count, not the string') if @w;
        my @rw = $E->rows('$WATCH/unknown.classic.jsonl', 'report_withheld');
        $E->count(\@rw, 1, 'one report_withheld row');
        $E->is($rw[0]{reason}, 'identity', 'row reason') if @rw;
        $E->is($rw[0]{file_kind}, 'rows', 'row file_kind') if @rw;
        $E->ok((index(join('', map { watch::json::encode($_) } @rw), 'canaryrepoalpha') < 0 ? 1 : 0), 'the row holds no string');
    },
};

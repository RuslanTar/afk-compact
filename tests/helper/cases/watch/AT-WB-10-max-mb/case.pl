# AT-WB-10 (W-BETA B.6; BUILD-ROUND-9 WCH-09): over `--max-mb` the newest rows are kept and the
# oldest dropped, the written zip fits the cap, the manifest says `truncated: true` with the
# `from` date of the oldest kept row, and the TRUNCATED line prints. STORE (no DEFLATE) is
# forced here so that the rows really take room.
my @rows;
for my $i (0 .. 7999) {
    push @rows, T::row('continue', -3 * 86400 + $i * 60, result => 'submitted', continues_last_hour => $i % 6,
                       turn_seq => $i);
}
my %got;
{
    files => [ { path => '$WATCH/$SID.jsonl', jsonl => \@rows } ],
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out', '--max-mb', '1' ],
          env => { STORE_TEST_NO_GIT => '1', STORE_TEST_ZIP_STORE => '1' },
          stdout_re => qr/^TRUNCATED: over --max-mb, the newest rows are kept \(from 2026-10-\d\d\)$/m },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z) = T::zips_in("$v->{TMP}/out");
              $got{size} = -s $z;
              $got{e} = T::zip_entries($z);
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok((($got{size} // 1e9) <= 1024 * 1024 ? 1 : 0), "the zip fits 1 MB ($got{size} bytes)");
        my $e = $got{e};
        my $m = eval { watch::json::decode($e->{'manifest.json'}{data}) } || {};
        $E->is($m->{window}{truncated}, 1, 'manifest truncated true');
        my ($rf) = grep { m{\Arows/} } keys %$e;
        my @r = map { watch::json::decode($_) } grep { /\S/ } split /\n/, ($e->{$rf}{data} // '');
        $E->ok((@r > 1000 && @r < 8000 ? 1 : 0), 'some rows kept, some dropped (' . scalar(@r) . ')');
        $E->is($r[-1]{turn_seq}, 7999, 'the newest row is kept');
        $E->ok((($r[0]{turn_seq} // 0) > 0 ? 1 : 0), 'the oldest rows are dropped');
        my ($d) = ($r[0]{ts} // '') =~ /\A([0-9-]{10})/;
        $E->is($m->{window}{from}, $d, 'window.from is the oldest kept row`s date');
    },
};

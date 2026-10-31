# Keep-warm (D-14), lane B (export schema): a ping that missed the main prefix exports its result
# and its gap's stop reason as `fork-miss` (live probe 2026-10-31: the fork's request did not read the
# main cache; the main cache had not lapsed). `lapsed` is no keep-warm class: it exports as `other`.
# Rows are given as the watcher reads them (booleans as 1 and 0).
my %got;
my @rows = (
    { ev => 'keep_warm_ping', n => 1, result => 'fork-miss', cache_read => 25289, cache_creation => 234319, since_s => 3000, gap_s => 3000, ms => 5000 },
    { ev => 'keep_warm_stop', why => 'fork-miss', pings => 1, gap_s => 3000, handover => 1 },
    { ev => 'keep_warm_ping', n => 1, result => 'warm', cache_read => 228161, cache_creation => 9, since_s => 3000, gap_s => 3000, ms => 5000 },
    { ev => 'keep_warm_ping', n => 1, result => 'lapsed', cache_read => 0, cache_creation => 228170, since_s => 3000, gap_s => 3000, ms => 5000 },
    { ev => 'keep_warm_stop', why => 'lapsed', pings => 1, gap_s => 3000, handover => 1 },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-31T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        $E->is(join(',', map { $o[0]{$_} } qw(result cache_read cache_creation)), 'fork-miss,25289,234319', 'a fork-miss ping exports as given');
        $E->is(join(',', $o[1]{why}, $o[1]{pings}), 'fork-miss,1', 'its stop exports as given');
        $E->is($o[2]{result}, 'warm', 'a warm ping');
        $E->is(join(',', $o[3]{result}, $o[4]{why}), 'other,other', 'lapsed is no keep-warm class any more: other');
    },
};

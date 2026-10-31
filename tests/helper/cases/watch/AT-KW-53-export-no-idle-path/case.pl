# Keep-warm (D-14), lane B (export schema): a gap no idle path could take over (no idle record
# armed or held, or triggers off) refuses before its first ping with one keep_warm_stop row, why
# `no-idle-path`, pings 0, no start row; a warming gap that stops for it exports alike.
# Rows are given as the watcher reads them (booleans as 1 and 0).
my %got;
my @rows = (
    { ev => 'keep_warm_stop', why => 'no-idle-path', pings => 0, gap_s => 3000, handover => 0 },
    { ev => 'keep_warm_stop', why => 'no-idle-path', pings => 1, gap_s => 6000, handover => 1 },
    { ev => 'keep_warm_stop', why => 'no-idle', pings => 0, gap_s => 3000, handover => 0 },
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
        $E->is(join(',', map { $o[0]{$_} } qw(why pings gap_s)), 'no-idle-path,0,3000', 'a refusal before the first ping exports as given');
        $E->is(join(',', $o[1]{why}, $o[1]{pings}), 'no-idle-path,1', 'a warming gap stopped for it exports as given');
        $E->is($o[2]{why}, 'other', 'an unknown reason is other');
    },
};

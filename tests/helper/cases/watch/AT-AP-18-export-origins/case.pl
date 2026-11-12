# AT-AP-18, watcher half:
# the approvals_carry row's `origins` (the carried approvals counted by the origin kind of the
# row their quote was found in) is exported as counts of fixed class words: a listed kind keeps
# its name, any other key becomes `other`, a value that is not a number is dropped. Nothing of
# the row is dropped as unknown.
my %got;
my @rows = (
    { ev => 'approvals_carry', source => 'summary', checked => 3, gate => 0, unchecked => 0, classes => [ 'push' ],
      origins => { human => 1, sdk => 1, dialog => 1 } },
    { ev => 'approvals_carry', source => 'handoff', checked => 4, gate => 1, unchecked => 0, classes => [],
      origins => { none => 1, composer => 1, unknown => 1, 'push feat/x' => 1, peer => 'x' } },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-26T20:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'helper', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        my $c = sub { my $h = shift || {}; return join(',', map { "$_=$h->{$_}" } sort keys %$h) };
        $E->is($c->($o[0]{origins}), 'dialog=1,human=1,sdk=1', 'listed origin kinds kept as counts');
        $E->is($c->($o[1]{origins}), 'composer=1,none=1,other=1,unknown=1', 'an unlisted key is other; a non-number is dropped');
        $E->is($o[0]{checked}, 3, 'the other fields as before');
    },
};

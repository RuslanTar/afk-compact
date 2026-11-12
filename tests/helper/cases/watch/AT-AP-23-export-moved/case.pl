# AT-AP-23, watcher half (0.1.3 APPROVALS): a written handoff_publish row counts the approval
# lines publish moved to Open questions in `approvals_moved` (a count, never a quote). The export
# keeps it as a number, so nothing of the row is dropped as unknown. 0.1.5: `lint_fixed`, the
# count of mechanical lints publish fixed itself, is kept the same way.
my %got;
my @rows = (
    { ev => 'handoff_publish', result => 'wrote', bytes => 4000, lint_rules => [ 'approval-quote' ], size_band => 'small',
      approvals => { lines => 1, checked => 1, unchecked => 0, hashed => 1 }, approval_classes => [ 'push' ], approvals_moved => 6,
      lint_fixed => 2 },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-21T14:05:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'helper', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        $E->is($o[0]{approvals_moved}, 6, 'approvals_moved exported as its count');
        $E->is($o[0]{lint_fixed}, 2, 'lint_fixed exported as its count');
        $E->is($o[0]{approvals}{checked}, 1, 'the other fields as before');
    },
};

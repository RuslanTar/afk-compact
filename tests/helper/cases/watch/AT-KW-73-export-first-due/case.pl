# Keep-warm, 0.1.13 (export schema): a gap's start row and a refused stop row name the first ping's
# due after the gap began (`first_due_s`) and why (`first_why`: `native-window`, 55:15, when Claude
# Code's own idle compaction may take the gap at 54 minutes; else `default`, 50 minutes). Both export
# as given; a reason outside the list exports as `other`. Rows are given as the watcher reads them (booleans as 1 and 0).
my %got;
my @rows = (
    { ev => 'keep_warm_start', jobs => 1, gap_s => 3315, hours => 6, windows => 2, ping_s => 3000, first_due_s => 3315, first_why => 'native-window' },
    { ev => 'keep_warm_start', jobs => 1, gap_s => 3000, hours => 6, windows => 2, ping_s => 3000, first_due_s => 3000, first_why => 'default' },
    { ev => 'keep_warm_stop', why => 'compacted', pings => 0, gap_s => 3315, handover => 0, refused => 1, first_due_s => 3315, first_why => 'native-window' },
    { ev => 'keep_warm_stop', why => 'no-jobs', pings => 0, gap_s => 3000, handover => 0, refused => 1, first_due_s => 3000, first_why => 'secret words' },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-11-15T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { $o[0]{$_} } qw(ev gap_s ping_s first_due_s first_why)), 'keep_warm_start,3315,3000,3315,native-window', 'a native-window start row exports its first due and reason');
        $E->is(join(',', map { $o[1]{$_} } qw(first_due_s first_why)), '3000,default', 'a default start row too');
        $E->is(join(',', map { $o[2]{$_} } qw(why pings first_due_s first_why)), 'compacted,0,3315,native-window', 'a refused stop row keeps them');
        $E->is(join(',', map { $o[3]{$_} } qw(first_due_s first_why)), '3000,other', 'a reason outside the list exports as other');
    },
};

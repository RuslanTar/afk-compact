# Keep-warm, 0.1.11 (export schema): every reason an armed gap does not warm writes one refused
# stop row (pings 0, `refused` true, a near-limit one with its windows and rule); a ping going out
# writes `keep_warm_send {n, gap_s, since_s}`; a fork that took over about 2 minutes or came back
# past the 58-minute bound is the ping result `late`, its gap stopped `missed`. All export as given.
# Rows are given as the watcher reads them (booleans as 1 and 0).
my %got;
my @rows = (
    { ev => 'keep_warm_stop', why => 'no-jobs', pings => 0, gap_s => 3000, handover => 0, refused => 1 },
    { ev => 'keep_warm_stop', why => 'near-limit', pings => 0, gap_s => 3000, handover => 0, refused => 1, windows => ['five_hour:95', 'seven_day:30'], rule => '90' },
    { ev => 'keep_warm_send', n => 1, gap_s => 6000, since_s => 3000 },
    { ev => 'keep_warm_ping', n => 1, result => 'late', cache_read => 228161, cache_creation => 9, since_s => 3000, gap_s => 6000, ms => 180000 },
    { ev => 'keep_warm_stop', why => 'missed', pings => 1, gap_s => 6180, handover => 0 },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-11-12T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        my $b = sub { my ($v) = @_; return ref $v ? $$v : $v };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        $E->is(join(',', (map { $o[0]{$_} } qw(why pings gap_s)), $b->($o[0]{handover}), $b->($o[0]{refused})), 'no-jobs,0,3000,0,1', 'a refused gap exports with its reason and the refused mark');
        $E->is(join(',', $o[1]{why}, $b->($o[1]{refused}), join('|', @{ $o[1]{windows} || [] }), $o[1]{rule}), 'near-limit,1,five_hour:95|seven_day:30,90', 'a near-limit refusal keeps its windows and rule');
        $E->is(join(',', map { $o[2]{$_} } qw(ev n gap_s since_s)), 'keep_warm_send,1,6000,3000', 'a ping going out exports');
        $E->is(join(',', $o[3]{result}, $o[3]{ms}), 'late,180000', 'a late ping exports its result');
        $E->is(join(',', $o[4]{why}, exists $o[4]{refused} ? 'refused' : 'warmed'), 'missed,warmed', 'its stop: missed, no refused mark');
    },
};

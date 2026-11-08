# D-76 (0.1.6, export schema): a near-limit skip row names the usage windows it read, each
# `kind:percent` (`arm:percent` from the idle record), on handoff_skipped and keep_warm_stop. The
# export keeps them in the reported order and drops an item that is not of that shape (free text,
# a number, a nested value); older rows without the field still export whole, nothing dropped.
my %got;
my @rows = (
    { ev => 'handoff_skipped', why => 'near-limit', reason => 'idle', ht => undef, kind => 'compact', windows => [qw(seven_day:94 five_hour:40)] },
    { ev => 'handoff_skipped', why => 'near-limit', reason => 'idle', ht => undef, kind => 'turn', windows => ['arm:95'] },
    { ev => 'handoff_skipped', why => 'near-limit', reason => 'idle', ht => undef, kind => 'check',
      windows => ['spend_limit:97', 'Seven Day: 94', 'five_hour:unknown', 42, { kind => 'x' }, 'opus_weekly:1234567', 'five_hour:-3'] },
    { ev => 'handoff_skipped', why => 'near-limit', reason => 'idle', ht => undef, kind => 'compact' },
    { ev => 'handoff_skipped', why => 'small', reason => 'idle', ht => undef, kind => 'turn' },
    { ev => 'keep_warm_stop', why => 'near-limit', pings => 1, gap_s => 3600, handover => 1, windows => [qw(five_hour:90 seven_day:30)] },
    { ev => 'keep_warm_stop', why => 'turn', pings => 2, gap_s => 6000, handover => 0 },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-11-08T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        my $w = sub { my $r = shift; return exists $r->{windows} ? join('|', @{ $r->{windows} }) : '-' };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped as a field');
        $E->is($w->($o[0]), 'seven_day:94|five_hour:40', 'the windows export in the order reported');
        $E->is($w->($o[1]), 'arm:95', 'the arm-time reading exports');
        $E->is($w->($o[2]), 'spend_limit:97|five_hour:unknown', 'items not kind:percent are dropped, the rest kept');
        $E->is(join(',', map { "$o[$_]{why}/$o[$_]{kind}/" . $w->($o[$_]) } 3, 4), 'near-limit/compact/-,small/turn/-', 'older rows without windows export whole');
        $E->is($w->($o[5]), 'five_hour:90|seven_day:30', 'keep_warm_stop near-limit windows');
        $E->is("$o[6]{why}/" . $w->($o[6]), 'turn/-', 'an older keep_warm_stop row exports whole');
    },
};

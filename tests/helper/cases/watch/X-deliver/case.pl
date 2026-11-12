# Alert delivery, built but shipped switched to status-only (E-17): with
# the switch set to system-message, one Stop prints one JSON object holding at
# most 3 alerts, critical first, each shown once (exclusive `delivered/` marker),
# warn at most 1 per rule, info never; no `decision` or `continue` field.
# The default mode prints nothing (every other case checks that).
my @t = (T::prompt(0), T::assistant_text(1));
for my $i (0 .. 3) {
    my $at = 100 + 400 * $i;
    push @t, T::prompt($at - 50), T::prompt($at - 40), T::prompt($at - 30), T::assistant_text($at - 20),
             T::boundary($at, trigger => 'manual'), T::summary($at + 0.1);
}
{
    # the session's first row (0.1.3: a session with no row yet is observed from its first Stop, and
    # these boundaries would be history)
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('config_note', 0, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] } ],
    transcript => \@t,
    steps => [
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'system-message' } },
        { call => 'stop', at => 1500, expect_output => 1 },
        { call => 'stop', at => 1510, expect_output => 1 },
        { call => 'stop', at => 1520, expect_output => 1 },
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'status-only' } },
    ],
    expect => sub {
        my ($E) = @_;
        my ($o1, $o2, $o3) = $E->outputs;
        $E->ok(defined $o1, 'first Stop prints');
        my $m1 = defined $o1 ? watch::json::decode($o1) : {};
        $E->is(join(',', sort keys %$m1), 'systemMessage', 'only systemMessage, no decision or continue');
        my @l1 = split /\n/, $m1->{systemMessage} // '';
        $E->count(\@l1, 4, 'three alerts plus the Details line');
        $E->is(scalar(grep { /test text 01/ } @l1), 3, 'critical A-01 first');
        $E->ok(($l1[-1] // '') eq "Details: /$T::BRAND:status", 'details line');
        my $m2 = defined $o2 ? watch::json::decode($o2) : {};
        my @l2 = split /\n/, $m2->{systemMessage} // '';
        $E->is(scalar(grep { /test text 01/ } @l2), 1, 'the fourth A-01 next Stop');
        $E->is(scalar(grep { /test text 15/ } @l2), 1, 'one warn A-15');
        $E->is($o3, undef, 'nothing left to show (info only)');
        opendir(my $d, $E->var('WATCH') . '/' . $E->var('SID') . '/delivered') or die;
        $E->count([ grep { !/\A\.\.?\z/ } readdir $d ], 5, 'five delivered markers');
    },
};

# T-19 (M-04): native auto at 770K with the 800K window ->
# band_position at-native; A-05. Thresholds from the settings clamp over
# the settings (no mod config row: classic-only). A second auto compaction in
# band raises nothing.
{
    settings => { native_window_tokens => 800000 },
    # the session's first row (0.1.3: a session with no row yet is observed from its first Stop, and
    # these boundaries would be history)
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('config_note', 0, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] } ],
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(10, trigger => 'auto', preTokens => 770000), T::summary(10.1),
        T::prompt(100), T::prompt(200), T::prompt(300), T::bash(302, 'make', id => 'toolu_2'), T::result(303, 'toolu_2'),
        T::boundary(310, trigger => 'auto', preTokens => 450000), T::summary(310.1),
    ],
    steps => [ { call => 'stop', at => 400 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->is($b[0]{band_position}, 'at-native', '770K at the 800K window');
        $E->is($b[1]{band_position}, 'in-band', '450K between target and soft max');
        my @a = $E->alerts('A-05');
        $E->count(\@a, 1, 'one A-05');
        $E->is($a[0]{evidence}{native_trigger}, 767000, 'native trigger = window - 33,000');
        $E->is($a[0]{evidence}{soft_max}, 600000, 'soft max');
    },
};

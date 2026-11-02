# AT-AN-13 (0.1.3 integration review): the `stop_timing` row a Stop writes last (hook speed) is
# one of the rows the Stop writes itself, like its sweep rows: it does not count as the
# session's first hook row (observed_from). Here an earlier Stop at 50 left only its stop_timing
# row and the first hook row came at 1000: the boundaries at 100 and 300 are history (no A-01,
# hookless A-15 or A-05), the one at 1500 raises all three, as in AT-AN-01.
{
    settings => { native_window_tokens => 800000 },
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('stop_timing', 50, writer => 'classic', ms => 420, start_ms => 30, reconcile_ms => 300,
                                   reconcile_budget_ms => 3000),
                            T::row('config_note', 1000, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] } ],
    transcript => [
        T::prompt(0), T::assistant_text(5),
        T::boundary(100, trigger => 'manual', preTokens => 450000), T::summary(100.1),
        T::prompt(200), T::assistant_text(210),
        T::boundary(300, trigger => 'auto', preTokens => 250000), T::summary(300.1),
        T::prompt(1100), T::assistant_text(1110),
        T::boundary(1500, trigger => 'auto', preTokens => 250000), T::summary(1500.1),
        T::prompt(1600),
    ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->boundaries ], 3, 'three boundaries recorded');
        for my $rule (qw(A-01 A-05)) {
            my @a = $E->alerts($rule);
            $E->count(\@a, 1, "$rule only for the boundary after the first hook row, not after the stop_timing row");
            $E->is($a[0]{key}{compaction_seq}, 3, "$rule names the observed compaction") if @a;
        }
        my @h = grep { $_->{evidence}{hookless_boundary} } $E->alerts('A-15');
        $E->count(\@h, 1, 'hookless A-15 only for the observed boundary');
        $E->is($h[0]{key}{compaction_seq}, 3, 'A-15 names the observed compaction') if @h;
    },
};

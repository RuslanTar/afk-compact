# AT-AN-01 (0.1.3 alert noise items 2 and 3): a boundary from before the session's first hook
# row (the sweep reads a transcript from offset 0, so a session resumed or forked after the
# install brings its earlier compactions) with no hook row or dispatch of its own was never
# observed: no A-01, no hookless A-15 and no A-05 for it. A boundary after that row with no copy
# and no hook row still raises A-01 and the hookless A-15 (the true case), and one out of the
# band A-05. The rows the Stop writes itself (sweep_partial here) do not count as the first row.
{
    settings => { native_window_tokens => 800000 },
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('sweep_partial', 50, writer => 'classic', reason => 'hard-stop', stage => 'sweep'),
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
        my @b = $E->boundaries;
        $E->count(\@b, 3, 'three boundaries recorded');
        $E->is(scalar(grep { ($_->{copy} // '') eq 'missing' } @b), 3, 'none has a copy');
        my @a01 = $E->alerts('A-01');
        $E->count(\@a01, 1, 'A-01 only for the boundary after the first hook row');
        $E->is($a01[0]{key}{compaction_seq}, 3, 'A-01 names the observed compaction') if @a01;
        my @a15 = grep { $_->{evidence}{hookless_boundary} } $E->alerts('A-15');
        $E->count(\@a15, 1, 'hookless A-15 only for the observed boundary');
        $E->is($a15[0]{key}{compaction_seq}, 3, 'A-15 names the observed compaction') if @a15;
        my @a05 = $E->alerts('A-05');
        $E->count(\@a05, 1, 'A-05 only for the observed boundary out of the band');
        $E->is($a05[0]{key}{compaction_seq}, 3, 'A-05 names the observed compaction') if @a05;
    },
};

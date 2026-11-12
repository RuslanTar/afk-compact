# T-22 (M-17): a continue row after a native auto compaction that no
# nudge drove -> A-27; a continue after 2 consecutive unshaped main verdicts
# (a halt condition) -> A-19.
my $body = "# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
my $pc = sub { my $at = shift; return { call => 'hook', event => 'PostCompact', at => $at,
                                        payload => { trigger => 'auto', compact_summary => $body },
                                        ctx => { detect => { verdict => 'unshaped', normalized => $body } } } };
{
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(100, trigger => 'auto'), T::summary(100.1),
        T::continue_row(110), T::assistant_text(115),
        T::prompt(200), T::prompt(300), T::prompt(400),
        T::bash(440, 'make', id => 'toolu_2'), T::result(441, 'toolu_2'), T::nudge(441.5), T::assistant_text(445),
        T::boundary(500, trigger => 'manual'), T::summary(500.1),
        T::continue_row(510), T::assistant_text(515),
    ],
    steps => [ $pc->(101), $pc->(501), { call => 'stop', at => 600 } ],
    expect => sub {
        my ($E) = @_;
        my @a27 = $E->alerts('A-27');
        $E->count(\@a27, 1, 'A-27 once: the second continue followed a nudge-driven compaction');
        my @a19 = grep { $_->{evidence}{continue_after_halt_cond} } $E->alerts('A-19');
        $E->count(\@a19, 1, 'A-19 after two unshaped verdicts');
        $E->is($a19[0]{severity}, 'critical', 'A-19 is critical');
    },
};

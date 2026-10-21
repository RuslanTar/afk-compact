# T-09 (WATCH §9): a plugin-origin continue row, plus a later user row quoting
# the same text with no origin -> auto_continue 1 (match on origin, never on
# text, M-17). The count over a session is W13; the sweep row marks the rows.
my $quote = "Note from the user's $T::BRAND plugin: CANARY-TEXT-continue";
{
    transcript => [
        T::prompt(0),
        T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::nudge(3.1),
        T::assistant_text(5),
        T::boundary(10, trigger => 'manual'), T::summary(10.1),
        T::continue_row(20),
        T::assistant_text(25),
        T::prompt(40, $quote),
        T::assistant_text(45),
    ],
    steps => [ { call => 'stop', at => 60 } ],
    expect => sub {
        my ($E) = @_;
        my ($sw) = $E->rows('classic', 'sweep');
        $E->is($sw->{turns}{continues}, 1, 'one plugin-origin continue');
        $E->is($sw->{turns}{plugin_origin_rows}, 1, 'the quoting user row is not plugin-origin');
        $E->is($sw->{turns}{prompts}, 3, 'turn starts counted');
        $E->is($sw->{turns}{nudges}, 1, 'the nudge row');
        $E->count([ $E->alerts('A-27') ], 0, 'a nudge-driven compaction: no A-27');
    },
};

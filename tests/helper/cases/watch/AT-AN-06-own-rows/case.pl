# AT-AN-06 (0.1.3 alert noise): a session whose streams hold only the rows the
# Stop writes itself (no SessionStart, mod or preamble row: the plugin was loaded mid-session on
# the classic path) is observed from the earliest of those rows. Here an earlier Stop at 1000
# left its sweep row and a later one at 1200; a boundary from before the first raises no A-01,
# hookless A-15 or A-05, and one after it raises all three, also one between the two (the
# earliest of them counts).
{
    settings => { native_window_tokens => 800000 },
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('sweep', 1000, writer => 'classic', file => "$T::SID.jsonl", boundaries => []),
                            T::row('sweep', 1200, writer => 'classic', file => "$T::SID.jsonl", boundaries => []) ] } ],
    transcript => [
        T::prompt(0), T::assistant_text(5),
        T::boundary(300, trigger => 'auto', preTokens => 250000), T::summary(300.1),
        T::prompt(1050), T::assistant_text(1060),
        T::boundary(1100, trigger => 'auto', preTokens => 250000), T::summary(1100.1),
        T::prompt(1300), T::assistant_text(1310),
        T::boundary(1500, trigger => 'auto', preTokens => 250000), T::summary(1500.1),
        T::prompt(1600),
    ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->boundaries ], 3, 'three boundaries recorded');
        for my $rule (qw(A-01 A-05)) {
            my @a = $E->alerts($rule);
            $E->is(join(',', sort map { $_->{key}{compaction_seq} } @a), '2,3', "$rule for the boundaries after the first Stop's row");
        }
        my @h = grep { $_->{evidence}{hookless_boundary} } $E->alerts('A-15');
        $E->is(join(',', sort map { $_->{key}{compaction_seq} } @h), '2,3', 'hookless A-15 for the boundaries after the first Stop row');
    },
};

# AT-AN-06 (0.1.3 alert noise, root decision 2): a session whose streams hold only the rows the
# Stop writes itself (no SessionStart, mod or preamble row: the plugin was loaded mid-session on
# the classic path) is observed from the earliest of those rows. Here an earlier Stop at 1000
# left its sweep row; a boundary from before it raises no A-01, hookless A-15 or A-05, and one
# after it raises all three.
{
    settings => { native_window_tokens => 800000 },
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('sweep', 1000, writer => 'classic', file => "$T::SID.jsonl", boundaries => []),
                            T::row('sweep', 1200, writer => 'classic', file => "$T::SID.jsonl", boundaries => []) ] } ],
    transcript => [
        T::prompt(0), T::assistant_text(5),
        T::boundary(300, trigger => 'auto', preTokens => 250000), T::summary(300.1),
        T::prompt(1100), T::assistant_text(1110),
        T::boundary(1500, trigger => 'auto', preTokens => 250000), T::summary(1500.1),
        T::prompt(1600),
    ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->boundaries ], 2, 'two boundaries recorded');
        for my $rule (qw(A-01 A-05)) {
            my @a = $E->alerts($rule);
            $E->count(\@a, 1, "$rule only for the boundary after the first Stop's row");
            $E->is($a[0]{key}{compaction_seq}, 2, "$rule names the later compaction") if @a;
        }
        my @h = grep { $_->{evidence}{hookless_boundary} } $E->alerts('A-15');
        $E->count(\@h, 1, 'hookless A-15 only for the later boundary');
        $E->is($h[0]{key}{compaction_seq}, 2, 'A-15 names the later compaction') if @h;
    },
};

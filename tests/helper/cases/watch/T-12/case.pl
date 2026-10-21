# T-12 (WATCH §9): 4 consecutive compactions, each 2 main turns after the
# previous (3 rapid refills) -> rapid_refill_run 3, thrash; A-07.
# (T-12-three holds the 3-compaction half.)
my @t = (T::prompt(0), T::assistant_text(5));
for my $i (0 .. 3) {
    my $at = 100 * ($i + 1);
    push @t, T::boundary($at, trigger => 'manual', preTokens => 420000, postTokens => 40000), T::summary($at + 0.1);
    push @t, T::prompt($at + 10), T::assistant_text($at + 20), T::prompt($at + 30), T::assistant_text($at + 40);
}
{
    transcript => \@t,
    steps => [ { call => 'stop', at => 600 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 4, 'four boundaries');
        $E->is($b[3]{rapid_refill_run}, 3, 'rapid_refill_run 3 at the 4th');
        $E->is($b[3]{turns_since_prev}, 2, 'two turns between compactions');
        $E->is($b[1]{refill_per_turn}, 190000, 'refill per turn');
        $E->count([ $E->alerts('A-07') ], 1, 'A-07');
    },
};

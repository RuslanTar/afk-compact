# T-12, second half: 3 such compactions -> rapid_refill_run 2; no A-07.
my @t = (T::prompt(0), T::assistant_text(5));
for my $i (0 .. 2) {
    my $at = 100 * ($i + 1);
    push @t, T::boundary($at, trigger => 'manual', preTokens => 420000), T::summary($at + 0.1);
    push @t, T::prompt($at + 10), T::assistant_text($at + 20), T::prompt($at + 30), T::assistant_text($at + 40);
}
{
    transcript => \@t,
    steps => [ { call => 'stop', at => 500 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 3, 'three boundaries');
        $E->is($b[2]{rapid_refill_run}, 2, 'rapid_refill_run 2');
        $E->count([ $E->alerts('A-07') ], 0, 'no A-07');
    },
};

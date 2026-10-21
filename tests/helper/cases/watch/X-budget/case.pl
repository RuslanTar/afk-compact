# WATCH §1.1/W9 budgets: a run reads at most RUN_BYTES (5 MB shipped; 700 B
# here); the rest is read at the next Stop (`sweep_partial`), whole lines only,
# each boundary once. A hard stop skips the rules and logs `sweep_partial`
# with reason hard-stop.
my @t = (map { T::prompt($_) } 1 .. 6);
push @t, T::assistant_text(8), T::boundary(10, trigger => 'manual'), T::summary(10.1), T::prompt(20);
{
    transcript => \@t,
    steps => [
        { call => 'code', code => sub { $watch::sweep::RUN_BYTES = 700 } },
        (map { { call => 'stop', at => 30 + $_ } } 1 .. 8),
        { call => 'code', code => sub { $watch::sweep::RUN_BYTES = 5 << 20 } },
        { call => 'append', rows => [ T::prompt(100), T::assistant_text(101) ] },
        { call => 'stop', at => 120, deadline => 0.000001 },
    ],
    expect => sub {
        my ($E) = @_;
        my @p = grep { ($_->{reason} // '') eq 'budget' } $E->rows('classic', 'sweep_partial');
        $E->ok(@p >= 2, 'budget partial rows');
        $E->count([ $E->boundaries ], 1, 'the boundary once');
        my @sw = grep { $_->{file} =~ /\.jsonl\z/ } $E->rows('classic', 'sweep');
        for my $i (1 .. $#sw) {
            $E->is($sw[$i]{from_off}, $sw[$i - 1]{to_off}, "sweep $i continues where the previous stopped");
        }
        $E->count([ grep { ($_->{reason} // '') eq 'hard-stop' } $E->rows('classic', 'sweep_partial') ], 1, 'hard stop row');
    },
};

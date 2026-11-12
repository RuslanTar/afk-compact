# W9 budgets: a run reads at most RUN_BYTES (5 MB shipped; 700 B
# here); the rest is read at the next Stop, whole lines only, each boundary
# once. Reading a backlog at that pace is normal: the sweep rows say
# `partial`, but no `sweep_partial` row is written and A-25 stays quiet. A hard
# stop logs `sweep_partial` with reason hard-stop and keeps nothing of its run:
# the next Stop reads the same bytes.
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
        { call => 'stop', at => 130 },
    ],
    expect => sub {
        my ($E) = @_;
        my @sw = grep { $_->{file} =~ /\.jsonl\z/ } $E->rows('classic', 'sweep');
        $E->ok(scalar(grep { Checker::truthy($_->{partial}) } @sw) >= 2, 'budget-paced sweep rows are partial');
        $E->count([ grep { ($_->{reason} // '') eq 'budget' } $E->rows('classic', 'sweep_partial') ], 0,
                  'no sweep_partial for the 5 MB pace');
        $E->count([ $E->alerts('A-25') ], 0, 'no A-25 for budget-paced reading');
        $E->count([ $E->boundaries ], 1, 'the boundary once');
        for my $i (1 .. $#sw) {
            $E->is($sw[$i]{from_off}, $sw[$i - 1]{to_off}, "sweep $i continues where the previous stopped");
        }
        $E->count([ grep { ($_->{reason} // '') eq 'hard-stop' } $E->rows('classic', 'sweep_partial') ], 1, 'hard stop row');
        $E->is($sw[-1]{turns}{prompts}, 1, 'the rows of the hard-stopped run are read by the next Stop');
    },
};

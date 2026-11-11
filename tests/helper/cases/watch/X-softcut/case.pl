# W9 soft limit: the sweeper checks the clock every 200 lines and stops
# reading once the soft limit has passed. Every line it consumed has been
# analyzed: here line 200 is a boundary and the limit is already past, so the
# cut comes after line 200 and the boundary is in the result. Then a real Stop
# (no limit hit) reads the whole file once.
my @t = map { T::prompt($_) } 1 .. 199;
push @t, T::boundary(300, trigger => 'manual', uuid => 'u-b-softcut'), T::summary(300.1),
         map { T::prompt(310 + $_) } 1 .. 250;
my %got;
{
    transcript => \@t,
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::sweep;
              my $state = {};
              my $r = watch::sweep::scan_file({ sid => $T::SID, brand => $T::BRAND }, $v->{TRANSCRIPT}, $state,
                                              5 << 20, 0, 'main', 1, []);
              %got = (lines => $state->{carry}{line}, bounds => scalar @{ $r->{boundaries} },
                      time_cut => $r->{time_cut}, partial => $r->{partial}, to_off => $r->{to_off},
                      size => -s $v->{TRANSCRIPT});
          } },
        { call => 'stop', at => 600 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{lines}, 200, 'the cut comes after 200 lines');
        $E->is($got{bounds}, 1, 'the boundary on line 200 was analyzed before the cut');
        $E->is($got{time_cut}, 1, 'a time cut');
        $E->ok($got{to_off} < $got{size}, 'the rest is left for the next Stop');
        $E->count([ grep { ($_->{reason} // '') eq 'time' } $E->rows('classic', 'sweep_partial') ], 0,
                  'no time cut in the real Stop');
        $E->count([ $E->boundaries ], 1, 'the real Stop finds the boundary once');
    },
};

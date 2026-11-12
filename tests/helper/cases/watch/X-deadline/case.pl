# F2-4: the rules run inside the Stop's hard
# stop. A fake clock here jumps past the hard stop as the rules write their
# `precompute_or_failed` row: the rules stop at their next clock check and the
# run is dropped (one `sweep_partial {reason: hard-stop, stage: rules}`, no
# sweep row, no offset kept). The next Stop evaluates the same input again:
# each alert once, the boundary once, and still one `precompute_or_failed` row
# (deduped against the stream, since the dropped run kept no session state).
my $fake = 1000;
my $mono = \&watch::io::mono;
my $log_row = \&watch::ctx::log_row;
{
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(500, trigger => 'auto', preTokens => 450000), T::summary(500.1), T::prompt(510) ],
    steps => [
        { call => 'hook', event => 'PreCompact', at => 10, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::io::mono = sub { $fake };
              *watch::ctx::log_row = sub {
                  my $r = $log_row->(@_);
                  $fake += 100 if ($_[1] // '') eq 'precompute_or_failed';
                  return $r;
              };
          } },
        { call => 'stop', at => 2000, deadline => 3 },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::io::mono = $mono;
              *watch::ctx::log_row = $log_row;
          } },
        { call => 'stop', at => 2010 },
    ],
    expect => sub {
        my ($E) = @_;
        my @hs = grep { ($_->{reason} // '') eq 'hard-stop' } $E->rows('classic', 'sweep_partial');
        $E->count(\@hs, 1, 'one hard-stop row');
        $E->is($hs[0]{stage}, 'rules', 'the clock ran out in the rules');
        $E->count([ $E->rows('classic', 'sweep') ], 1, 'no sweep row from the dropped run');
        $E->count([ $E->boundaries ], 1, 'the boundary once');
        $E->count([ $E->alerts('A-01') ], 1, 'A-01 once');
        $E->count([ $E->alerts('A-06') ], 1, 'A-06 once');
        $E->count([ $E->rows('classic', 'precompute_or_failed') ], 1, 'one precompute_or_failed row');
        $E->count([ $E->rows('classic', 'watch_error') ], 0, 'no watch_error');
    },
};

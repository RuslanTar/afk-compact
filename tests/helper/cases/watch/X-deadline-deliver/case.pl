# ROOT-RULINGS F2-4 (SAFE-02), WATCH W9 / §7.2: delivery runs only before the
# Stop's hard stop. With delivery switched to system-message, a fake clock
# passes the hard stop right after the run is committed (sweep rows and
# offsets saved): that Stop prints nothing and leaves no `delivered/` marker,
# and the next Stop delivers the alert.
my $fake = 1000;
my $mono = \&watch::io::mono;
my $finish;
my $after1;
{
    transcript => [ T::prompt(0), T::assistant_text(1), T::boundary(100, trigger => 'manual'), T::summary(100.1), T::prompt(110) ],
    steps => [
        { call => 'code', code => sub {
              no warnings 'redefine';
              require watch::sweep;
              $watch::alerts::DELIVERY = 'system-message';
              $finish = \&watch::sweep::finish;
              *watch::io::mono = sub { $fake };
              *watch::sweep::finish = sub { my @r = $finish->(@_); $fake += 100; return @r };
          } },
        { call => 'stop', at => 600, deadline => 3, expect_output => 1 },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::io::mono = $mono;
              *watch::sweep::finish = $finish;
              my ($v) = @_;
              $after1 = scalar grep { !/\A\.\.?\z/ } watch::io::list_dir("$v->{WATCH}/$T::SID/delivered");
          } },
        { call => 'stop', at => 610, expect_output => 1 },
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'status-only' } },
    ],
    expect => sub {
        my ($E) = @_;
        my ($o1, $o2) = $E->outputs;
        $E->is($o1, undef, 'nothing printed past the hard stop');
        my $m2 = defined $o2 ? watch::json::decode($o2) : {};
        $E->ok(scalar(($m2->{systemMessage} // '') =~ /test text 01/), 'the next Stop delivers the A-01 alert');
        $E->count([ $E->alerts('A-01') ], 1, 'one A-01');
        $E->count([ $E->rows('classic', 'sweep') ], 1, 'the late run was committed (its sweep row)');
        $E->count([ $E->rows('classic', 'sweep_partial') ], 0, 'no sweep_partial for a late delivery');
        $E->is($after1, 0, 'no delivered marker from the late Stop');
        my $dir = $E->var('WATCH') . '/' . $E->var('SID') . '/delivered';
        $E->ok(scalar(grep { !/\A\.\.?\z/ } watch::io::list_dir($dir)) >= 1, 'delivered markers from the second Stop');
    },
};

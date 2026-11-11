# F2-4: the incremental cache load runs inside
# the Stop's hard stop too. A fake clock passes the hard stop while the mod
# stream is read: no rule runs on part of a stream, the run is dropped (one
# `sweep_partial {reason: hard-stop, stage: load}`, no sweep row), but the
# lines the cache read are kept (state.json), so the next Stop goes on from
# that offset and evaluates everything once.
my $fake = 1000;
my $mono = \&watch::io::mono;
my $read;
my %mid;
my @noise_m = map { T::row('skip', 1 + $_ / 100, why => 'cooldown') } 1 .. 200;
{
    transcript => [ T::prompt(0), T::assistant_text(1), T::boundary(100, trigger => 'manual'), T::summary(100.1), T::prompt(110) ],
    files => [ { path => '$WATCH/$SID.jsonl', jsonl => [ @noise_m, T::row('thrash', 50) ] } ],
    steps => [
        { call => 'code', code => sub {
              no warnings 'redefine';
              require watch::cache;
              $read = \&watch::cache::_read_stream;
              *watch::io::mono = sub { $fake };
              *watch::cache::_read_stream = sub { $fake += 100 if $_[1] eq 'mod'; goto &$read };
          } },
        { call => 'stop', at => 600, deadline => 3 },
        { call => 'code', code => sub {
              my ($v) = @_;
              no warnings 'redefine';
              *watch::io::mono = $mono;
              *watch::cache::_read_stream = $read;
              my $st = watch::io::read_json_file("$v->{WATCH}/$T::SID/watch-cache/state.json") || {};
              %mid = (off => $st->{src}{mod}{off}, size => -s "$v->{WATCH}/$T::SID.jsonl",
                      alerts => scalar(grep { /"A-07"/ } split /\n/, (watch::io::slurp("$v->{WATCH}/$T::SID.alerts.jsonl") // '')));
          } },
        { call => 'stop', at => 610 },
    ],
    expect => sub {
        my ($E) = @_;
        my @hs = grep { ($_->{reason} // '') eq 'hard-stop' } $E->rows('classic', 'sweep_partial');
        $E->count(\@hs, 1, 'one hard-stop row');
        $E->is($hs[0]{stage}, 'load', 'the clock ran out in the cache load');
        $E->ok(($mid{off} // 0) > 0 && ($mid{off} // 0) < ($mid{size} // 0),
               'the cut load kept its progress (mod offset ' . ($mid{off} // 'undef') . ' of ' . ($mid{size} // 'undef') . ')');
        $E->is($mid{alerts}, 0, 'no rule ran on part of the stream');
        $E->count([ grep { $_->{evidence}{mod_thrash} } $E->alerts('A-07') ], 1, 'the next Stop read the rest: A-07 once');
        $E->count([ $E->rows('classic', 'sweep') ], 1, 'one sweep row, from the second Stop');
        $E->count([ $E->boundaries ], 1, 'the boundary once');
        $E->count([ $E->alerts('A-01') ], 1, 'A-01 once');
    },
};

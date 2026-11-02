# HS-04 (0.1.3 hook speed, watch/rules.pm _watch_mb): A-24's watch-folder size is walked at most
# once an hour per session; the size is kept in the session state. The walk grows with the store
# (every session's folder, up to 20,000 entries) and ran at every Stop. A Stop with a small folder
# keeps its size; a 12 MB file added after it is not walked again by a Stop 100 s later (no A-24,
# the folder is not listed). A Stop more than an hour after the walk walks again; this walk runs
# long and gives up at half of the time left before the run's hard stop: the run still commits
# (its sweep row, no `sweep_partial {reason: hard-stop}`) and keeps no size, so the next Stop walks
# again and raises the A-24 watch-size warning. A slow walk is simulated by a clock that moves
# 0.25 s at each of the walk's clock reads (40 folders to walk, a 3 s window): the walk gives up
# 1.5 s in, the rules and the commit run before the 3 s hard stop. A walk that ran to the hard
# stop itself left the next tick() to drop the whole run.
my ($after_first, $after_second, $after_slow, $sweeps_before, $walk_ts_before, $walk_ts_after);
my $size_alerts = sub {
    my ($v) = @_;
    my $rows = watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.alerts.jsonl") || [];
    return scalar grep { ($_->{rule} // '') eq 'A-24' && ref $_->{evidence} eq 'HASH' && $_->{evidence}{watch_dir} } @$rows;
};
my $sweeps = sub {
    my ($v) = @_;
    my $rows = watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.classic.jsonl") || [];
    return scalar grep { ($_->{ev} // '') eq 'sweep' } @$rows;
};
my $walk_ts = sub {
    my ($v) = @_;
    my $st = watch::io::read_json_file("$v->{WATCH}/$v->{SID}/offsets/$v->{SID}.jsonl.off") || {};
    return ref $st->{session} eq 'HASH' && ref $st->{session}{watch_mb} eq 'HASH' ? $st->{session}{watch_mb}{ts} : undef;
};
my $late_walk;
my ($real_mono, $real_dir, $in_walk, $skew) = (undef, undef, 0, 0);
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    settings => { watch_quota_mb => 10 },
    steps => [
        { call => 'stop', at => 100 },
        { call => 'code', code => sub { $after_first = $size_alerts->($_[0]) } },
        { call => 'write', path => '$WATCH/bulk/filler.json', json => { pad => ('w' x (12 << 20)) } },
        { call => 'stop', at => 200 },
        { call => 'code', code => sub { $after_second = $size_alerts->($_[0]) } },
        # a slow walk over an hour later: it gives up, the run goes on and commits, nothing is kept
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{WATCH}/bulk/d$_") for 1 .. 40;
              $sweeps_before = $sweeps->($v);
              $walk_ts_before = $walk_ts->($v);
              no warnings 'redefine';
              $real_mono = \&watch::io::mono;
              $real_dir = \&watch::rules::_dir_mb;
              *watch::io::mono = sub { return $real_mono->() + ($in_walk ? ($skew += 0.25) : $skew) };
              *watch::rules::_dir_mb = sub { $in_walk = 1; my $r = $real_dir->(@_); $in_walk = 0; return $r };
          } },
        { call => 'append', rows => [ T::prompt(3790), T::assistant_text(3791) ] },
        { call => 'stop', at => 100 + 3700, deadline => 3 },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::io::mono = $real_mono;
              *watch::rules::_dir_mb = $real_dir;
              $walk_ts_after = $walk_ts->($_[0]);
              $after_slow = $size_alerts->($_[0]);
          } },
        # the next Stop walks again (the slow walk kept nothing) and raises the warning
        { call => 'stop', at => 100 + 3800 },
        # the walk itself: past its deadline it gives up ('late'), it does not die
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::rules;
              $late_walk = watch::rules::_dir_mb($v->{WATCH}, 20000, watch::io::mono() - 1);
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($after_first, 0, 'first Stop: a small folder, no A-24');
        $E->is($after_second, 0, 'a Stop 100 s later reuses the kept size: no new walk, no A-24');
        my @a = grep { ref $_->{evidence} eq 'HASH' && $_->{evidence}{watch_dir} } $E->alerts('A-24');
        $E->is($after_slow, 0, 'the slow walk an hour later gave up: no size, no A-24');
        $E->count(\@a, 1, 'the next Stop walks again: one A-24 watch-size');
        $E->ok(@a && $a[0]{evidence}{mb} >= 12, 'A-24 evidence names the folder size in MB') if @a;
        $E->is($late_walk, 'late', 'a walk past its deadline gives up');
        $E->ok($skew >= 1.25 && $skew < 3, "the slow walk gave up about halfway to the hard stop (clock moved ${skew} s)");
        my @hs = grep { ($_->{reason} // '') eq 'hard-stop' } $E->rows('classic', 'sweep_partial');
        $E->count(\@hs, 0, 'a walk that gives up does not drop the run (no sweep_partial hard-stop)');
        my $after = scalar(() = $E->rows('classic', 'sweep'));
        $E->ok($after > ($sweeps_before // 0), "the run with the slow walk committed its sweep row ($sweeps_before before, $after after)");
        $E->is($walk_ts_after, $walk_ts_before, 'the walk that gave up kept no size (the hour-old one stays)');
    },
};

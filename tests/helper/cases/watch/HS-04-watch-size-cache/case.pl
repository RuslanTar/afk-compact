# HS-04 (0.1.3 hook speed, watch/rules.pm _watch_mb): A-24's watch-folder size is walked at most
# once an hour per session; the size is kept in the session state. The walk grows with the store
# (every session's folder, up to 20,000 entries) and ran at every Stop. A Stop with a small folder
# keeps its size; a 12 MB file added after it is not walked again by a Stop 100 s later (no A-24,
# the folder is not listed); a Stop more than an hour after the walk walks again and raises the
# A-24 watch-size warning. A walk that reaches the run's hard stop gives up without dropping the run.
my ($after_first, $after_second);
my $size_alerts = sub {
    my ($v) = @_;
    my $rows = watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.alerts.jsonl") || [];
    return scalar grep { ($_->{rule} // '') eq 'A-24' && ref $_->{evidence} eq 'HASH' && $_->{evidence}{watch_dir} } @$rows;
};
my $late_walk;
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    settings => { watch_quota_mb => 10 },
    steps => [
        { call => 'stop', at => 100 },
        { call => 'code', code => sub { $after_first = $size_alerts->($_[0]) } },
        { call => 'write', path => '$WATCH/bulk/filler.json', json => { pad => ('w' x (12 << 20)) } },
        { call => 'stop', at => 200 },
        { call => 'code', code => sub { $after_second = $size_alerts->($_[0]) } },
        { call => 'stop', at => 100 + 3700 },
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
        $E->count(\@a, 1, 'a Stop over an hour after the walk walks again: one A-24 watch-size');
        $E->ok(@a && $a[0]{evidence}{mb} >= 12, 'A-24 evidence names the folder size in MB') if @a;
        $E->is($late_walk, 'late', 'a walk past its deadline gives up');
    },
};

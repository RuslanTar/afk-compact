# AT-CK-10 (SK-6): watch_quota_mb drives A-24's watch-size
# warning (watch/rules.pm). With a 12 MB watch folder, 0 (= off) raises nothing; 10 raises one
# A-24 with the folder's size. Warn only: nothing in the folder is removed.
my $after_off;
my $size_alerts = sub {
    my ($v) = @_;
    my $rows = watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.alerts.jsonl") || [];
    return scalar grep { ($_->{rule} // '') eq 'A-24' && ref $_->{evidence} eq 'HASH' && $_->{evidence}{watch_dir} } @$rows;
};
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    files => [ { path => '$WATCH/bulk/filler.bin', text => ('w' x (12 << 20)) } ],
    steps => [
        { call => 'stop', at => 100, ctx => { settings => { watch_quota_mb => 0 } } },
        { call => 'code', code => sub { $after_off = $size_alerts->($_[0]) } },
        { call => 'stop', at => 200, ctx => { settings => { watch_quota_mb => 10 } } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($after_off, 0, 'watch_quota_mb 0: no A-24 watch-size for a 12 MB folder');
        my @a = grep { ref $_->{evidence} eq 'HASH' && $_->{evidence}{watch_dir} } $E->alerts('A-24');
        $E->count(\@a, 1, 'watch_quota_mb 10: one A-24 watch-size');
        $E->is($a[0]{evidence}{mb}, 12, 'A-24 evidence names the folder size in MB') if @a;
        $E->ok(-s $E->path('$WATCH/bulk/filler.bin') == (12 << 20), 'the folder is left as it was');
    },
};

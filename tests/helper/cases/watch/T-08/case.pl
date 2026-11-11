# T-08 (shared with AT-M5-08): the sidecar ring is plugin core
# (core writes bg/slot-<k>.json at Stop/SubagentStop). The watcher's part:
# it reads the ring, dedupes ids across slots (one shell id repeated in all
# 20 slots counts once: one A-11 at most per id), and never writes a slot.
# 0.1.3 alert noise: an item with no known output path (the teammate) raises
# no A-11 (AT-AN-03); the shells name an output path (missing here, so quiet).
my $old = $T::BASE - 2 * 3600;
my @files;
for my $k (0 .. 19) {
    push @files, { path => "\$WATCH/\$SID/bg/slot-$k.json", mtime => $old + 60 * $k,
                   json => { set_hash => "h$k", tasks => [ { id => 'tm-1', type => 'teammate', status => 'running' },
                                                           { id => 'sh-r', type => 'shell', status => 'running', output_path => '$TMP/none' },
                                                           ($k % 2 ? { id => "sh-$k", type => 'shell', status => 'running',
                                                                       output_path => '$TMP/none' } : ()) ] } };
}
{
    settings => { stall_min => 60 },
    files => \@files,
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [ { call => 'stop', at => 30 }, { call => 'stop', at => 90 } ],
    expect => sub {
        my ($E) = @_;
        my %id = map { ($_->{alert_id} => 1) } $E->alerts('A-11');
        $E->ok($id{ watch::alerts::alert_id('A-11', $T::SID, 'sh-r') } ? 1 : 0, 'the repeated shell id raises A-11');
        $E->count([ $E->alerts('A-11') ], 2, 'one stall alert per id over two Stops (sh-r and the last slot\'s sh-19)');
        $E->ok($id{ watch::alerts::alert_id('A-11', $T::SID, 'tm-1') } ? 0 : 1, 'the teammate with no output path raises none');
        opendir(my $dh, $E->var('WATCH') . '/' . $E->var('SID') . '/bg') or die;
        my @slots = grep { /\Aslot-/ } readdir $dh;
        $E->count(\@slots, 20, 'the watcher wrote no slot');
    },
};

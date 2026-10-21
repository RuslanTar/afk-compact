# T-08 (WATCH §9, shared with AT-M5-08): the sidecar ring is plugin core
# (WP-core writes bg/slot-<k>.json at Stop/SubagentStop). The watcher's part:
# it reads the ring, dedupes ids across slots (one teammate id repeated in all
# 20 slots counts once: one A-11 at most per id), and never writes a slot.
my $old = $T::BASE - 2 * 3600;
my @files;
for my $k (0 .. 19) {
    push @files, { path => "\$WATCH/\$SID/bg/slot-$k.json", mtime => $old + 60 * $k,
                   json => { set_hash => "h$k", tasks => [ { id => 'tm-1', type => 'teammate', status => 'running' },
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
        my @a = grep { $_->{evidence}{output_known} == 0 } $E->alerts('A-11');
        $E->count(\@a, 1, 'the repeated teammate id is one stall alert over two Stops');
        opendir(my $dh, $E->var('WATCH') . '/' . $E->var('SID') . '/bg') or die;
        my @slots = grep { /\Aslot-/ } readdir $dh;
        $E->count(\@slots, 20, 'the watcher wrote no slot');
    },
};

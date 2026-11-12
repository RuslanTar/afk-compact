# AT-WD-03: no hook path runs `watch prune`; a hand-run
# `watch prune` takes a session only when EVERY file of it is older than the cut. That includes
# the per-session files other parts keep under <watch>/<sid>/ (jobs.jsonl and
# jobs-pending.jsonl, queue-adds.jsonl, handoff-turn/, the watcher's own
# config-note-watcher): an old set goes whole, one new file anywhere in it keeps the whole
# set, a symlink keeps it. <watch>/queue-caps.json and the other global files are never
# touched.
my $old = $T::BASE + 3600 - 40 * 86400;
my $new = $T::BASE + 3600 - 86400;
my ($A, $B, $C) = ('aaaaaaaa-1111-4111-8111-111111111111', 'bbbbbbbb-2222-4222-8222-222222222222',
                   'cccccccc-3333-4333-8333-333333333333');
my @per_sid = map { [ $_, "{\"x\":1}\n" ] } qw(jobs.jsonl jobs-pending.jsonl queue-adds.jsonl handoff-turn/abcd0001.json
                                              handoff-turn/abcd0001.stage handoff-turn/abcd0001.published config-note-watcher);
my $files = sub { my ($sid, $mt) = @_; return map { { path => "\$WATCH/$sid/$_->[0]", text => $_->[1], mtime => $mt } } @per_sid };
my $body = "# CANARY-TEXT-topic\n";
{
    files => [
        { path => "\$WATCH/$A.classic.jsonl", text => "{}\n", mtime => $old },
        $files->($A, $old),
        { path => "\$WATCH/$B.classic.jsonl", text => "{}\n", mtime => $old },
        $files->($B, $old),
        { path => "\$WATCH/$B/handoff-turn/abcd0002.published", text => "x\n", mtime => $new },
        { path => "\$WATCH/$C.classic.jsonl", text => "{}\n", mtime => $old },
        $files->($C, $old),
        { path => '$WATCH/queue-caps.json', text => "{}\n", mtime => $old },
        { path => '$WATCH/heal/x/item.count', text => "1\n", mtime => $old },
    ],
    transcript => [ T::prompt(0), T::boundary(10, trigger => 'auto'), T::summary(10.1) ],
    steps => [
        { call => 'code', code => sub { my $v = shift; mkdir "$v->{TMP}/target"; symlink("$v->{TMP}/target", "$v->{WATCH}/$C/handoff-turn/link") } },
        # a full hook sequence: none of it prunes
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
        { call => 'stop', at => 30 },
        { call => 'status', at => 31 },
        { call => 'code', code => sub { my $v = shift; $main::PRUNE_ROWS_BEFORE = scalar(grep { ($_->{ev} // '') eq 'watch_prune' }
                                                           map { @{ watch::io::read_jsonl("$v->{WATCH}/$_") || [] } }
                                                           grep { /\.classic\.jsonl\z/ } watch::io::list_dir($v->{WATCH})) } },
        { call => 'cli', argv => ['watch', 'prune', '--days', '30'], exit => 0, stdout_re => qr/\Apruned files=8 bytes=\d+\n\z/ },
    ],
    expect => sub {
        my ($E) = @_;
        my $w = $E->var('WATCH');
        $E->is($main::PRUNE_ROWS_BEFORE, 0, 'no watch_prune row after a full hook sequence');
        $E->ok(!-e "$w/$A.classic.jsonl" && !-e "$w/$A", 'the old set goes whole, per-session files and handoff-turn/ included');
        $E->ok(-e "$w/$B.classic.jsonl" && -e "$w/$B/jobs.jsonl" && -e "$w/$B/handoff-turn/abcd0001.json" && -e "$w/$B/queue-adds.jsonl",
               'one new file under handoff-turn/ keeps the whole session');
        $E->ok(-e "$w/$C.classic.jsonl" && -l "$w/$C/handoff-turn/link" && -e "$w/$C/jobs-pending.jsonl", 'a symlink inside handoff-turn/ keeps the set');
        $E->ok(-e "$w/queue-caps.json" && -e "$w/heal/x/item.count", 'queue-caps.json and the other global files are untouched');
        $E->ok(-d $E->var("TMP") . "/target", "the symlink target is untouched");
        $E->count([ $E->rows('$WATCH/unknown.classic.jsonl', 'watch_prune') ], 1, 'one watch_prune row, from the hand-run command');
    },
};

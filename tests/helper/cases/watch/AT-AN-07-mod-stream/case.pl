# AT-AN-07 (0.1.3 alert noise, review test gaps m21 and m17): the session's first row may be in
# its mod stream (`<sid>.jsonl`), which counts as much as the classic one: the mod's row at 400
# comes before the classic stream's first row (the Stop's own, at 1000). A boundary at 100 is
# history (no A-01); one at 500 is observed (A-01). A boundary from before that row that has a
# dispatch of its own (at 249, joined by time) was observed too: A-01 for it.
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('sweep', 1000, writer => 'classic', file => "$T::SID.jsonl", boundaries => []) ] },
        { path => '$WATCH/$SID.jsonl', jsonl => [ T::row('config_note', 400, writer => 'mod', key => 'k', note => 'n') ] },
        { path => '$WATCH/$SID/dispatch/2d2e0001.json', json => T::dispatch('2d2e0001', 249) },
    ],
    transcript => [
        T::prompt(0), T::assistant_text(5),
        T::boundary(100, trigger => 'manual', preTokens => 450000), T::summary(100.1), T::prompt(200),
        T::boundary(250, trigger => 'auto', preTokens => 450000), T::summary(250.1), T::prompt(300),
        T::boundary(500, trigger => 'manual', preTokens => 450000), T::summary(500.1), T::prompt(600),
    ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 3, 'three boundaries recorded');
        $E->is(join(',', map { $_->{join} // '-' } @b), '-,time,-', 'the one at 250 is joined to its dispatch');
        my @a = sort { $a <=> $b } map { $_->{key}{compaction_seq} } $E->alerts('A-01');
        $E->is(join(',', @a), '2,3', 'A-01 for the joined boundary and the one after the mod row, not for history');
    },
};

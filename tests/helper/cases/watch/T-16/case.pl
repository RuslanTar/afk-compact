# T-16 (WATCH §9): a malformed JSON line and an unreadable transcript ->
# watch_error rows; no stdout; the hook path exits 0. The rows after the bad
# line are still swept.
{
    needs => [q(nonroot)], needs_note => q(chmod 0 does not stop root reading the transcript, so no unreadable row; the whole case skips),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'append', raw => "{\"type\":\"user\", not json\n" },
        { call => 'append', rows => [ T::assistant_text(5), T::boundary(10, trigger => 'manual'), T::summary(10.1) ] },
        { call => 'stop', at => 20 },
        { call => 'append', rows => [ T::prompt(30) ] },
        { call => 'chmod', path => '$PROJ/$SID.jsonl', mode => 0 },
        { call => 'stop', at => 40 },
        { call => 'chmod', path => '$PROJ/$SID.jsonl', mode => 0600 },
        { call => 'cli', argv => ['hook', 'Stop'], stdin => "not json {", exit => 0 },
        { call => 'cli', argv => ['hook', 'PostCompact'], stdin => '', exit => 0 },
    ],
    expect => sub {
        my ($E) = @_;
        my @e = $E->rows('classic', 'watch_error');
        $E->count([ grep { $_->{stage} eq 'sweep' && $_->{error_class} eq 'bad-json' } @e ], 1, 'bad-json row');
        $E->count([ grep { $_->{stage} eq 'sweep' && $_->{error_class} eq 'unreadable' } @e ], 1, 'unreadable row');
        my ($sw) = $E->rows('classic', 'sweep');
        $E->is($sw->{bad_lines}, 1, 'one bad line counted');
        $E->count([ $E->boundaries ], 1, 'the boundary after the bad line is found');
    },
};

# AT-WD-07 (A-18, DP-14 (6)): a halt `continue` row, the plugin-submitted handoff turn of
# the same ht, and a `handoff_publish wrote` row in that turn: no A-18. Before the handoff
# turn exists (a Stop right after the halt row) nothing is raised either.
my $ht = 'abcd0007';
{
    files => [ { path => '$WATCH/$SID.jsonl',
                 jsonl => [ T::row('continue', 100, result => 'halt:cap', continues_last_hour => 1) ] } ],
    transcript => [ T::prompt(0), T::assistant_text(50) ],
    steps => [
        { call => 'stop', at => 102 },                                        # the nudged turn's Stop: no ht yet, 2 s old
        { call => 'write', path => "\$WATCH/\$SID/handoff-turn/$ht.json",
          json => { v => 1, ht => $ht, session_id => $T::SID, reason => 'cap', max_calls => 34, max_tokens => 64000,
                    opened_at => T::loc(101) } },
        { call => 'append', rows => [ T::continue_row(103), T::bash(110, 'x publish', id => 'toolu_7'), T::result(111, 'toolu_7') ] },
        { call => 'append', path => '$WATCH/$SID.classic.jsonl',
          rows => [ T::row('handoff_publish', 112, writer => 'helper', result => 'wrote', bytes => 4000, ht => $ht) ] },
        { call => 'stop', at => 130 },                                        # the handoff turn's Stop
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->alerts('A-18') ], 0, 'no A-18: the handoff turn wrote the handoff');
        my ($sw) = grep { $_->{handoff_turn} } $E->rows('classic', 'sweep');
        $E->ok($sw && $sw->{handoff_turn}[0]{ht} eq $ht, 'the submit was seen as the handoff turn');
    },
};

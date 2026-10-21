# AT-WD-08 (A-18): the handoff turn ran (submit swept) and nothing was published: A-18 warn,
# once, at the Stop that ends the handoff turn, not at the earlier Stop (nothing yet).
my $ht = 'abcd0008';
{
    files => [ { path => '$WATCH/$SID.jsonl',
                 jsonl => [ T::row('continue', 100, result => 'halt:2-nonok', continues_last_hour => 1) ] } ],
    transcript => [ T::prompt(0), T::assistant_text(50) ],
    steps => [
        { call => 'stop', at => 102 },
        { call => 'write', path => "\$WATCH/\$SID/handoff-turn/$ht.json",
          json => { v => 1, ht => $ht, session_id => $T::SID, reason => '2-nonok', max_calls => 34, max_tokens => 64000,
                    opened_at => T::loc(101) } },
        { call => 'append', rows => [ T::continue_row(103), T::assistant_text(120) ] },
        { call => 'stop', at => 130 },
        { call => 'stop', at => 160 },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-18');
        $E->count(\@a, 1, 'A-18 once');
        $E->is($a[0]{severity}, 'warn', 'warn');
        $E->is($a[0]{evidence}{result}, 'halt:2-nonok', 'the halt result');
    },
};

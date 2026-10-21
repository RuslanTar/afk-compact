# T-23 (WATCH §9, M-15): an unshaped main compaction whose resume block lacks
# the non-ok note; a resume block of 10,500 chars -> A-23 twice. The
# resume_inject rows are core's (`claim`) and the mod's; here they are given.
my ($n1, $n2) = ('8e8e0001', '8e8e0002');
my $unshaped = "# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
my $ok = T::main_body(nonce => $n2);
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n1.json",
          json => T::dispatch($n1, 99, actor => 'unknown', channel => 'classic', resume_pref => 'sessionstart') },
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => T::dispatch($n2, 499) },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('resume_inject', 100.05, writer => 'classic', nonce => $n1, channel => 'sessionstart',
                            bytes => 3000, nonok_note => \0) ] },
        { path => '$WATCH/$SID.jsonl',
          jsonl => [ T::row('resume_inject', 502, nonce => $n2, channel => 'prompt.context', bytes => 10500, nonok_note => \0) ] },
    ],
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(100, trigger => 'auto'), T::summary(100.1),
        T::prompt(200), T::prompt(300), T::prompt(400), T::bash(402, 'make', id => 'toolu_2'), T::result(403, 'toolu_2'),
        T::boundary(500, trigger => 'auto'), T::summary(500.1),
    ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 101, payload => { trigger => 'auto', compact_summary => $unshaped },
          ctx => { detect => { verdict => 'unshaped', normalized => $unshaped } } },
        { call => 'hook', event => 'PostCompact', at => 501, payload => { trigger => 'auto', compact_summary => $ok },
          ctx => { detect => { verdict => 'ok', nonce => $n2, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => $ok } } },
        { call => 'stop', at => 600 },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-23');
        $E->count(\@a, 2, 'A-23 twice');
        $E->count([ grep { $_->{evidence}{nonok_note_missing} } @a ], 1, 'non-ok note missing');
        $E->count([ grep { $_->{evidence}{resume_over_10k} } @a ], 1, 'block over 10,000');
        my @b = $E->boundaries;
        $E->is($b[0]{nonce}, $n1, 'unshaped compaction joined to the classic dispatch by time');
    },
};

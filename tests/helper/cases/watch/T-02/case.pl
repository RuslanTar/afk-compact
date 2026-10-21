# T-02 (WATCH §9): mod-driven compaction; the summary row right after the
# boundary, postTokens after preservedMessages -> parsed by key; trigger plugin
# from the self-call dispatch (M-01).
my $n = 'a0a00002';
my $raw = '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info",'
        . '"parentUuid":null,"isSidechain":false,"sessionId":"' . $T::SID . '","uuid":"u-b-t02",'
        . '"timestamp":"' . T::z(10) . '","version":"2.1.306","compactMetadata":{"trigger":"manual",'
        . '"preTokens":410000,"preservedMessages":{"anchorUuid":"x","uuids":[],"allUuids":[]},'
        . '"postTokens":41000,"cumulativeDroppedTokens":0,"durationMs":35605}}' . "\n";
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8, channel => 'mod-self', trigger => 'plugin') } ],
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        { call => 'append', raw => $raw },
        { call => 'append', rows => [ T::summary(10.1), T::prompt(20) ] },
        { call => 'hook', event => 'PostCompact', at => 11,
          payload => { trigger => 'manual', compact_summary => '<summary>' . T::main_body(nonce => $n) . '</summary>' },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => T::main_body(nonce => $n) } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 1, 'one boundary');
        $E->is($b[0]{trigger}, 'plugin', 'M-01 trigger from the self-call dispatch');
        $E->is($b[0]{trigger_src}, 'dispatch', 'trigger source');
        $E->is($b[0]{boundary_trigger}, 'manual', 'raw boundary trigger kept');
        $E->is($b[0]{post}, 41000, 'postTokens parsed by key after preservedMessages');
        $E->is($b[0]{summary_line}, $b[0]{line} + 1, 'summary row right after the boundary');
        $E->is($b[0]{nonce}, $n, 'joined by nonce');
        $E->is($b[0]{verdict}, 'ok', 'verdict');
        $E->count([ $E->alerts('A-02') ], 0, 'no A-02 on an ok verdict');
    },
};

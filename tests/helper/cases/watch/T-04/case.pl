# T-04 (WATCH §9): precompute dispatch, then a boundary with precomputed:true,
# durationMs 20 -> joined; excluded from failure and thrash; verdict stale even
# when the nonce matches (nonce_match recorded apart, HK-61).
# The rollup's `verdict: stale` is core's (compactions.jsonl); this case checks
# the watcher's joined boundary record.
my $n = 'b0b00004';
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 2, trigger => 'precompute') } ],
    transcript => [
        T::prompt(0),
        T::bash(3, 'ls', id => 'toolu_a'),
        T::result(4, 'toolu_a'),
        T::boundary(10, trigger => 'auto', precomputed => \1, durationMs => 20, preTokens => 780000),
        T::summary(10.1),
    ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11,
          payload => { trigger => 'auto', compact_summary => T::main_body(nonce => $n) },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => T::main_body(nonce => $n) } } },
        { call => 'stop', at => 1200 },
    ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 1, 'one boundary');
        $E->is($b[0]{verdict}, 'stale', 'precomputed install is stale whatever the nonce');
        $E->is($b[0]{nonce_match}, 1, 'nonce_match recorded apart');
        $E->is($b[0]{trigger_detail}, 'precompute-installed', 'trigger_detail');
        $E->is($b[0]{duration_ms}, 20, 'duration kept on the record');
        $E->is($b[0]{rapid_refill_run}, undef, 'excluded from thrash counting');
        $E->count([ $E->alerts('A-17') ], 0, 'no failure for a precompute');
        $E->count([ $E->alerts('A-01') ], 0, 'no save-gap alert for a precompute');
        $E->count([ $E->alerts('A-07') ], 0, 'no thrash');
        $E->count([ $E->alerts('A-05') ], 0, 'no band alert for a precompute');
    },
};

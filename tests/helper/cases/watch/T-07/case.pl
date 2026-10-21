# T-07 (WATCH §9): subagent compaction with its boundary only in
# subagents/agent-<id>.jsonl and the PostCompact under the parent sid ->
# actor <id>; no main record; a summary with s=main -> A-03.
my $n = 'd0d00007';
my $agent = 'a9a00b3f363327444';
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json",
                 json => T::dispatch($n, 49, actor => 'unknown', channel => 'classic', resume_pref => 'sessionstart') } ],
    transcript => [ T::prompt(0), T::tool(2, 'Agent', { description => 'CANARY-TEXT-agent', prompt => 'x' }, id => 'toolu_ag') ],
    subagents => { $agent => [ T::prompt(3, 'CANARY-TEXT-task', sid => $T::SID),
                               T::bash(20, 'make', id => 'toolu_mk'), T::result(21, 'toolu_mk'),
                               T::boundary(50, trigger => 'auto', preTokens => 160000),
                               T::summary(50.1) ] },
    steps => [
        { call => 'hook', event => 'PreCompact', at => 49, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'hook', event => 'PostCompact', at => 51,
          payload => { trigger => 'auto', compact_summary => T::main_body(nonce => $n) },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => T::main_body(nonce => $n) } } },
        { call => 'stop', at => 90 },
    ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 1, 'one boundary (the subagent one)');
        $E->is($b[0]{attributed}, $agent, 'attributed to the agent');
        $E->count([ grep { ($_->{attributed} // '') eq 'main' } @b ], 0, 'no main record');
        $E->is($b[0]{verdict}, 'scope-leak', 's=main in a subagent compaction');
        $E->count([ $E->alerts('A-03') ], 1, 'A-03');
        $E->count([ $E->alerts('A-01') ], 0, 'save gap counts main only');
        my ($sw) = grep { $_->{actor} eq $agent } $E->rows('classic', 'sweep');
        $E->ok($sw, 'a sweep row for the subagent file');
    },
};

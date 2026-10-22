# T-15 extended (WATCHER-SPEC M-06, A-16; P5-FOLD A5; BUILD-ROUND-9 WCH-07): a subagent's
# compaction can set off bypass_suspected (P5: the one bypass row was a subagent's). The
# PostCompact has the parent sid and no agent id, there is only the classic fallback
# dispatch (no mod dispatch), the mod ran this turn; the boundary is in the agent's transcript. A-16 fires, and its row has
# `actor: unknown` (classic payloads carry no agent id). The text is the spec's
# `alert_texts.A-16` (WP-text renders the "possibly in a subagent" wording).
my $agent = 'a9a00b3f363327445';
my $n = 'd0d00015';
my $body = "# CANARY-TEXT-topic\n## Task as assigned\nCANARY-TEXT-body\n";
my $spec = main::spec_for_tests();
$spec->{alert_texts}{'A-16'} = "plugin: the plugin's compaction hook was skipped by a managed plugin (possibly in a subagent); the classic hooks shaped and saved it.";
{
    spec => $spec,
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json",
                 json => T::dispatch($n, 49, actor => 'unknown', channel => 'classic', resume_pref => 'sessionstart') },
               { path => '$WATCH/$SID/mod-alive.json',
                 json => { pid => 4242, pid_lstart => 'Tue Oct 21 13:00:00 2026', load_id => 'L1', turn_id => 'p-78',
                           ts => T::loc(1) } } ],
    transcript => [ T::prompt(0), T::tool(2, 'Agent', { description => 'CANARY-TEXT-agent', prompt => 'x' }, id => 'toolu_ag') ],
    subagents => { $agent => [ T::prompt(3, 'CANARY-TEXT-task', sid => $T::SID),
                               T::bash(20, 'make', id => 'toolu_mk'), T::result(21, 'toolu_mk'),
                               T::boundary(50, trigger => 'auto', preTokens => 160000), T::summary(50.1) ] },
    steps => [
        { call => 'hook', event => 'PostCompact', at => 51,
          payload => { trigger => 'auto', compact_summary => $body, prompt_id => 'p-78' },
          ctx => { detect => { verdict => 'unshaped', scope => 'sub', normalized => $body } } },
        { call => 'stop', at => 90 },
        { call => 'status', at => 95 },
    ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->is($b[0]{attributed}, $agent, 'the subagent boundary');
        $E->is($b[0]{bypass_suspected}, 1, 'bypass_suspected on a subagent compaction');
        my @a = $E->alerts('A-16');
        $E->count(\@a, 1, 'A-16 for the subagent compaction');
        $E->is($a[0]{actor}, 'unknown', 'the A-16 row has actor unknown') if @a;
        $E->is($a[0]{severity}, 'warn', 'first in the session is warn') if @a;
        my ($l) = $E->outputs;
        my $all = join("\n", @{ $l || [] });
        $E->ok((index($all, '(possibly in a subagent); the classic hooks shaped and saved it.') >= 0 ? 1 : 0),
               'status shows the A-16 text from the spec');
    },
};

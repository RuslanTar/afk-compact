# E-W-6 (provisional; needs W-1 from WP-text, text-escalations E-T9-5): the A-16 text in the
# spec starts with `{{plugin}}: ` (WATCHER-SPEC A-16), and Stop delivery shows alerts as
# `<brand> watcher: <text> (<alert_id>)` (handoff-spec §13). The delivered line names the
# plugin once: the watcher drops a leading `<brand>: ` from the text. `/status` keeps the
# spec text as it is. Delivery switched to system-message for this case (E-17 ships
# status-only).
my $agent = 'a9a00b3f363327445';
my $n = 'd0d00016';
my $body = "# CANARY-TEXT-topic\n## Task as assigned\nCANARY-TEXT-body\n";
my $spec = main::spec_for_tests();
my $a16 = "the plugin's compaction hook was skipped by a managed plugin (possibly in a subagent); the classic hooks shaped and saved it.";
$spec->{alert_texts}{'A-16'} = "$T::BRAND: $a16";
{
    spec => $spec,
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json",
                 json => T::dispatch($n, 49, actor => 'unknown', channel => 'classic', resume_pref => 'sessionstart') },
               { path => '$WATCH/$SID/mod-alive.json',
                 json => { pid => 4242, pid_lstart => 'Tue Oct 21 13:00:00 2026', load_id => 'L1', turn_id => 'p-78',
                           ts => T::loc(1) } } ],
    transcript => [ T::prompt(0), T::tool(2, 'Agent', { description => 'CANARY-TEXT-agent', prompt => 'x' }, id => 'toolu_ag') ],
    subagents => { $agent => [ T::prompt(3, 'CANARY-TEXT-task', sid => $T::SID),
                               T::boundary(50, trigger => 'auto', preTokens => 160000), T::summary(50.1) ] },
    steps => [
        { call => 'hook', event => 'PostCompact', at => 51,
          payload => { trigger => 'auto', compact_summary => $body, prompt_id => 'p-78' },
          ctx => { detect => { verdict => 'unshaped', scope => 'sub', normalized => $body } } },
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'system-message' } },
        { call => 'stop', at => 90, expect_output => 1 },
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'status-only' } },
        { call => 'status', at => 95 },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-16');
        $E->count(\@a, 1, 'A-16 raised') or return;
        my ($o, $st) = $E->outputs;
        my $m = defined $o ? watch::json::decode($o) : {};
        my ($l) = grep { /A-16|a16-/ || index($_, $a16) >= 0 } split /\n/, $m->{systemMessage} // '';
        $E->is($l, "$T::BRAND watcher: $a16 ($a[0]{alert_id})", 'the delivered line names the plugin once');
        my $all = join("\n", @{ $st || [] });
        $E->ok((index($all, "$T::BRAND: $a16") >= 0 ? 1 : 0), 'status shows the spec text as it is');
    },
};

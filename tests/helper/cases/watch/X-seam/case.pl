# ctx seam (lib/watch/ctx.pm): core may inject its own envelope builder
# `row(ev, fields, ctx)`. That signature carries no actor or writer, so the
# watcher keeps the ones it wrote the row for; everything else is core's.
my $n = 'abab0001';
my $agent = 'a7a7c0de00000001';
my $body = "## Task as assigned\nCANARY-TEXT-task\n## Report\nCANARY-TEXT-report\n";
my $core_row = sub {
    my ($ev, $f, $c) = @_;
    return { v => 1, ts => '2026-10-21T14:00:00.000+03:00', ev => $ev, sid => $c->{sid}, actor => 'unknown',
             writer => 'helper', pid => 7, plugin_version => '0.1.0', cc_version => undef, turn_seq => 41,
             built_by_core => \1, %$f };
};
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8, actor => $agent, agent_id => $agent) } ],
    steps => [
        { call => 'hook', event => 'StopFailure', at => 12, payload => { error => 'overloaded' }, ctx => { row => $core_row } },
        { call => 'hook', event => 'PostCompact', at => 13, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { row => $core_row,
                   detect => { verdict => 'ok', nonce => $n, scope => 'sub', marker_line => 1, sentinel_from_end => 1,
                               normalized => $body } } },
    ],
    expect => sub {
        my ($E) = @_;
        my ($s) = $E->rows('classic', 'stop_failure');
        $E->is($s->{actor}, 'main', 'stop_failure keeps actor main');
        $E->is($s->{writer}, 'helper', "core's writer kept when the watcher names none");
        $E->is($s->{turn_seq}, 41, "core's envelope fields kept");
        $E->is($s->{built_by_core}, 1, "core's builder was used");
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{actor}, $agent, 'postcompact keeps the dispatch actor');
    },
};

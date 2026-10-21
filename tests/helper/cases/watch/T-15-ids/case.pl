# T-15 with real id kinds (WATCH M-06, MOD-SPEC §3.3): the mod's liveness
# file carries the `turn.start` turnId, the PostCompact payload a prompt_id;
# they are different ids. A file written at this turn's start still counts ->
# bypass_suspected; A-16. (A-26 also fires: with no dispatch at all the
# channel is `none`, which A-26 covers on its own.)
my $body = "# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
{
    files => [ { path => '$WATCH/$SID/mod-alive.json',
                 json => { pid => 4242, pid_lstart => 'Tue Oct 21 13:00:00 2026', load_id => 'L1',
                           turn_id => 'turn-0b1c', ts => T::loc(1) } } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'manual'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11,
          payload => { trigger => 'manual', compact_summary => $body, prompt_id => '9f1e2d3c-0000-4000-8000-000000000077' },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{mod_alive_this_turn}, 1, 'written at this turn, whatever the id kinds');
        my @b = $E->boundaries;
        $E->is($b[0]{bypass_suspected}, 1, 'bypass_suspected');
        $E->is($b[0]{mod_off}, 0, 'not mod_off');
        $E->count([ $E->alerts('A-16') ], 1, 'A-16');
    },
};

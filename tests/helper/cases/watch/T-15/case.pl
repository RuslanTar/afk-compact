# T-15 (M-06): PostCompact with no dispatch, the mod loaded (its
# liveness file written in this turn, by this process), no self-call ->
# bypass_suspected; A-16 (warn at the first in a session).
my $body = "# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
{
    files => [ { path => '$WATCH/$SID/mod-alive.json',
                 json => { pid => 4242, pid_lstart => 'Tue Oct 21 13:00:00 2026', load_id => 'L1', turn_id => 'p-77',
                           ts => T::loc(1) } } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'manual'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11,
          payload => { trigger => 'manual', compact_summary => $body, prompt_id => 'p-77' },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{mod_alive_this_turn}, 1, 'the mod ran this turn');
        my @b = $E->boundaries;
        $E->is($b[0]{bypass_suspected}, 1, 'bypass_suspected');
        $E->is($b[0]{mod_off}, 0, 'not mod_off');
        my @a = $E->alerts('A-16');
        $E->count(\@a, 1, 'A-16');
        $E->is($a[0]{severity}, 'warn', 'first in the session is warn');
    },
};

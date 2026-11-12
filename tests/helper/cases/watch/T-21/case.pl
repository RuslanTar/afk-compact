# T-21 (M-06): PostCompact with no dispatch; the liveness file was
# NOT written in this turn (its ts is older than the turn's prompt) ->
# mod_off; A-26. (T-15 holds the "written this turn" half -> A-16.)
my $body = "# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
{
    files => [ { path => '$WATCH/$SID/mod-alive.json',
                 json => { pid => 4242, pid_lstart => 'Tue Oct 21 13:00:00 2026', load_id => 'L1', ts => T::loc(-600) } } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'auto'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{mod_alive_this_turn}, 0, 'liveness file is from an earlier turn');
        my @b = $E->boundaries;
        $E->is($b[0]{mod_off}, 1, 'mod_off');
        $E->is($b[0]{bypass_suspected}, 0, 'not bypass_suspected');
        $E->count([ $E->alerts('A-26') ], 1, 'A-26');
        $E->count([ $E->alerts('A-16') ], 0, 'no A-16');
    },
};

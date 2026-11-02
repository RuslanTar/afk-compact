# WATCH W9 hard stop: a Stop that runs out of time logs `sweep_partial`
# (reason hard-stop) and keeps no offset, so the boundary it had read is
# evaluated at the next Stop instead of being skipped: one A-01 for the
# compaction without a copy, one boundary record.
{
    # the session's first row (0.1.3: a session with only the Stop's own rows is observed from the
    # first of them, and this boundary would be history)
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('config_note', 0, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'auto', preTokens => 450000), T::summary(10.1), T::prompt(20) ],
    steps => [ { call => 'stop', at => 30, deadline => 0.000001 }, { call => 'stop', at => 60 } ],
    expect => sub {
        my ($E) = @_;
        $E->count([ grep { ($_->{reason} // '') eq 'hard-stop' } $E->rows('classic', 'sweep_partial') ], 1, 'hard stop row');
        $E->count([ $E->rows('classic', 'sweep') ], 1, 'no sweep row from the hard-stopped run');
        $E->count([ $E->boundaries ], 1, 'the boundary once');
        $E->count([ $E->alerts('A-01') ], 1, 'the boundary is evaluated at the next Stop');
    },
};

# AT-AN-19 (0.1.4 W-2): A-27 (a plugin continue after a main boundary that no nudge drove) skips the
# boundaries A-01, A-05 and the hookless A-15 skip: one from before the session's first row (a history
# boundary: all 12 A-27 rows of the 0.1.2 log were continues after such a boundary, hours later) and an
# idle compaction (here by Claude Code's native idle notice, W-16). The boundary is swept at one Stop
# and its continue at the next, so what the first Stop learned of it is kept. A continue after an
# observed, un-nudged auto boundary still raises A-27.
my $notice = sub { my ($t) = @_; return { type => 'system', subtype => 'informational', content => 'Compacted while idle for 1h',
                                           level => 'info', uuid => T::uid(), sessionId => $T::SID, timestamp => T::z($t) } };
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 500, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), T::boundary(100, uuid => 'b-hist', trigger => 'auto'), T::summary(100.1) ],
    steps => [
        { call => 'stop', at => 550 },
        { call => 'append', rows => [ T::continue_row(600), T::assistant_text(601),
                                      T::boundary(700, uuid => 'b-idle', trigger => 'auto'), $notice->(700.2), T::summary(700.3) ] },
        { call => 'stop', at => 750 },
        { call => 'append', rows => [ T::continue_row(800), T::assistant_text(801),
                                      T::boundary(900, uuid => 'b-obs', trigger => 'auto'), T::summary(900.1),
                                      T::continue_row(1000), T::assistant_text(1001) ] },
        { call => 'stop', at => 1100 },
    ],
    expect => sub {
        my ($E) = @_;
        my %b = map { ($_->{uuid} => $_) } $E->boundaries;
        $E->is(($b{'b-idle'} || {})->{idle_notice}, 'notice', 'the sweep marks the boundary the idle notice follows');
        $E->is(($b{'b-hist'} || {})->{idle_notice}, undef, 'and no other');
        my @a = $E->alerts('A-27');
        $E->count(\@a, 1, 'one A-27: the continue after the observed boundary');
        $E->is(@a ? $a[0]{evidence}{line} : undef, 14, 'the last continue (transcript line 14)');
    },
};

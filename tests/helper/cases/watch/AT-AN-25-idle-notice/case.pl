# AT-AN-25 (0.1.4 W-16): the sweep reads Claude Code's own idle notice: the first "Compacted while
# idle" or "Compacted using a summary written while you were away" system row after a main boundary
# (before the next one) marks it `idle_notice` (`notice` | `return`), the rule core's reconcile settles
# the rollup idle by. A-05 skips such a native idle compaction with no dispatch and no rollup idle;
# an auto compaction below the target with no notice still raises A-05.
my $sys = sub { my ($t, $text) = @_; return { type => 'system', subtype => 'informational', content => $text, level => 'info',
                                               uuid => T::uid(), sessionId => $T::SID, timestamp => T::z($t) } };
{
    settings => { native_window_tokens => 800000 },
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5),
                    T::boundary(100, uuid => 'b-notice', trigger => 'auto', preTokens => 250000), T::summary(100.1),
                    $sys->(100.2, 'Compacted while idle for 2h'), T::prompt(900),
                    T::boundary(1000, uuid => 'b-return', trigger => 'auto', preTokens => 250000), T::summary(1000.1),
                    $sys->(1000.2, 'Compacted using a summary written while you were away'), T::prompt(1400),
                    T::boundary(1500, uuid => 'b-plain', trigger => 'auto', preTokens => 250000), T::summary(1500.1),
                    $sys->(1500.2, 'Some other notice; Compacted while idle is not at its start'), T::prompt(1600) ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        my %b = map { ($_->{uuid} => $_) } $E->boundaries;
        $E->is(join(',', map { ($b{$_} || {})->{idle_notice} // '-' } qw(b-notice b-return b-plain)), 'notice,return,-',
               'the boundaries the notices follow are marked; a row that only contains the words is not one');
        $E->is(join(',', map { ($b{$_} || {})->{band_position} // '-' } qw(b-notice b-return b-plain)), 'below-target,below-target,below-target',
               'all three below the target');
        my @a = $E->alerts('A-05');
        $E->count(\@a, 1, 'A-05 only for the compaction with no idle notice');
        $E->is($a[0]{key}{compaction_seq}, 3, 'the third one') if @a;
    },
};

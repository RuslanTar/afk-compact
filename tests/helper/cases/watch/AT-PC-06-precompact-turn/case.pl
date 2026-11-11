# AT-PC-06 (M-17, A-18, A-19): the
# pre-compaction turn (`precompact_turn: model`, ht reason `precompact`) is a handoff turn
# for M-17: its plugin-origin submit is logged as `handoff_turn`, never as a continue, so it
# is no A-19 input (even at cap 0) and no A-27 input. A-18 does not apply to it: a
# published precompact turn never stands in for the missing last-cycle handoff of a
# `halt:` continue row, and a `handoff_skipped why: again` (the precompact skip) does not
# settle a halt row early, nor does any skip of the optional turn (`reason: precompact`).
my ($hp, $hq) = ('abcd0101', 'abcd0102');
my $rec = sub { my ($h, $t) = @_; return { v => 1, ht => $h, session_id => $T::SID, reason => 'precompact', max_calls => 34,
                                           max_tokens => 64000, opened_at => T::loc($t) } };
my $after_first;
{
    settings => { max_auto_continues_per_hour => 0 },
    files => [
        { path => "\$WATCH/\$SID/handoff-turn/$hp.json", json => $rec->($hp, 98) },
        { path => "\$WATCH/\$SID/handoff-turn/$hq.json", json => $rec->($hq, 305) },
        { path => "\$WATCH/\$SID/handoff-turn/$hq.published", text => '' },
        { path => '$WATCH/$SID.jsonl',
          jsonl => [ T::row('handoff_turn_start', 99, ht => $hp, reason => 'precompact', gap_s => undef),
                     T::row('continue', 300, result => 'halt:cap', continues_last_hour => 0),
                     T::row('continue', 600, result => 'halt:cap', continues_last_hour => 0),
                     T::row('handoff_skipped', 610, why => 'again', reason => undef, ht => undef),
                     T::row('handoff_skipped', 612, why => 'asks-user', reason => 'precompact', ht => undef),
                     T::row('handoff_skipped', 614, why => 'headroom', reason => 'precompact', ht => undef) ] },
    ],
    transcript => [
        T::prompt(0), T::assistant_text(5),
        T::continue_row(100), T::assistant_text(105),     # the precompact submit (ht opened at 98)
        T::continue_row(306), T::assistant_text(310),     # the second precompact submit (ht opened at 305)
    ],
    steps => [
        { call => 'stop', at => 630 },
        { call => 'code', code => sub { my ($v) = @_;
              $after_first = scalar grep { ($_->{rule} // '') eq 'A-18' }
                  @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID.alerts.jsonl") } } },
        { call => 'stop', at => 800 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($sw) = $E->rows('classic', 'sweep');
        $E->is($sw->{turns}{handoff_turns}, 2, 'both precompact submits are handoff turns');
        $E->is($sw->{turns}{continues}, 0, 'neither is a continue');
        $E->count([ $E->alerts('A-19') ], 0, 'no A-19 at cap 0: a handoff turn is not a continue');
        $E->count([ $E->alerts('A-27') ], 0, 'no A-27');
        $E->is($after_first, 1, 'first Stop: A-18 for the 300 s halt row only (a published precompact turn is no last-cycle handoff; the again skip settles nothing)');
        $E->count([ $E->alerts('A-18') ], 2, 'second Stop: the 600 s halt row settles by time');
    },
};

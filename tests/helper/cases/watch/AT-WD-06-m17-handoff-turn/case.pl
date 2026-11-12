# AT-WD-06 (M-17, A-19, A-27): a plugin-origin `user` row that follows an open
# handoff-turn record (handoff-turn/<ht>.json) is the plugin-submitted handoff turn: logged
# as `handoff_turn` (sweep row `handoff_turn`, turns.handoff_turns), never as a continue.
# It is not an A-27 input (a compaction no nudge drove) and not an A-19 input, even with
# max_auto_continues_per_hour 0. One submit per ht: a second plugin-origin row is a
# continue. A plugin-origin row with no ht record is a continue.
my $ht = 'abcd0001';
my $rec = sub { my ($h, $t) = @_; return { v => 1, ht => $h, session_id => $T::SID, reason => 'cap', max_calls => 34,
                                           max_tokens => 64000, opened_at => T::loc($t) } };
{
    settings => { max_auto_continues_per_hour => 0 },
    # the session's first row comes before the boundary: it was observed (0.1.4: A-27 skips a boundary
    # from before the session's first row, as A-01, A-05 and the hookless A-15 do)
    files => [ { path => "\$WATCH/\$SID/handoff-turn/$ht.json", json => $rec->($ht, 98) },
               { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] } ],
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(90, trigger => 'auto'), T::summary(90.1),                # no nudge drove it
        T::continue_row(100), T::assistant_text(105),                        # the handoff submit (ht opened at 98)
        T::continue_row(110), T::assistant_text(115),                        # a second plugin row: ht is used up
    ],
    steps => [ { call => 'stop', at => 200 } ],
    expect => sub {
        my ($E) = @_;
        my ($sw) = $E->rows('classic', 'sweep');
        $E->is($sw->{turns}{plugin_origin_rows}, 2, 'two plugin-origin rows');
        $E->is($sw->{turns}{handoff_turns}, 1, 'one of them is the handoff turn');
        $E->is($sw->{turns}{continues}, 1, 'the other is a continue');
        $E->is(scalar(@{ $sw->{handoff_turn} || [] }), 1, 'the sweep row names the handoff turn');
        $E->is($sw->{handoff_turn}[0]{ht}, $ht, 'by its ht');
        $E->is($sw->{turns}{prompts}, 3, 'it is a turn start (prompts counted)');
        my @a27 = $E->alerts('A-27');
        $E->count(\@a27, 1, 'A-27 once: only the real continue, not the handoff submit');
        $E->is($a27[0]{evidence}{line}, 8, 'the A-27 row is the second plugin row');
        my @a19 = $E->alerts('A-19');
        $E->count(\@a19, 1, 'A-19 (cap 0) once: the real continue only');
    },
};

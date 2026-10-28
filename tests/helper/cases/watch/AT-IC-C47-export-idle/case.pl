# IDLE-COMPACT-SPEC §2.3, lane B (export schema): the idle rows of the plugin's own idle compaction
# export as given: handoff_skipped's new reasons (error included), its kind and late_s; idle_mode's
# vetoed / compaction-off, plugin_compact (check: lane B and owner Q2; agents: lane A), compact_min
# and cache_s; idle_compact's at, late_s and adopted; idle_compact_off. A value outside an enum
# exports as `other`. Rows are given as the watcher reads them (booleans as 1 and 0).
my %got;
my @why = qw(lapsed present newer-turn due-missing prefix-changed adopted-cold input-ended compact-off compaction-off error);
my @rows = (
    (map { { ev => 'handoff_skipped', why => $_, reason => 'idle', ht => undef, kind => 'compact', late_s => 30 } } @why),
    { ev => 'handoff_skipped', why => 'agents-running', reason => 'idle', ht => undef, kind => 'check' },
    { ev => 'handoff_skipped', why => 'small', reason => 'idle', ht => undef, kind => 'turn' },
    { ev => 'handoff_skipped', why => 'some-new-reason', reason => 'idle', ht => undef, kind => 'nap' },
    { ev => 'idle_mode', native => 'vetoed', plugin_turn => 'on', plugin_compact => 'on', compact_min => 200000, cache_s => 600 },
    { ev => 'idle_mode', native => 'compaction-off', plugin_turn => 'off', plugin_compact => 'off' },
    { ev => 'idle_mode', native => 'on', plugin_turn => 'check', plugin_compact => 'check', compact_min => 300000 },
    { ev => 'idle_mode', native => 'on', plugin_turn => 'check', plugin_compact => 'agents', compact_min => 200000 },
    { ev => 'idle_mode', native => 'vetoed', plugin_turn => 'on', plugin_compact => 'failed' },
    { ev => 'idle_mode', native => 'sideways', plugin_turn => 'on', plugin_compact => 'maybe' },
    { ev => 'idle_compact', gap_s => 3240, tokens => 260000, agents => 0, at => 'timer', late_s => 0, adopted => 0 },
    { ev => 'idle_compact', gap_s => 3330, tokens => 260000, agents => 1, at => 'check', late_s => 30, adopted => 1 },
    { ev => 'idle_compact', gap_s => 3330, tokens => 260000, agents => 1, at => 'later' },
    { ev => 'idle_compact_off', why => 'failed', fails => 2 },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-27T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        my $b = sub { my $v = shift; return ref $v eq 'SCALAR' ? ($$v ? 'true' : 'false') : defined $v ? "<$v>" : 'null' };
        my $n = scalar @why;
        $E->is(join(',', map { $o[$_]{why} } 0 .. $n - 1), join(',', @why), 'the new skip reasons export as given');
        $E->is(join(',', map { "$o[$_]{kind}/$o[$_]{late_s}" } 0 .. $n - 1), join(',', ('compact/30') x $n), 'kind and late_s');
        $E->is("$o[$n]{why}/$o[$n]{kind}", 'agents-running/check', 'a check row');
        $E->is("$o[$n + 1]{why}/$o[$n + 1]{kind}", 'small/turn', 'a turn row');
        $E->is("$o[$n + 2]{why}/$o[$n + 2]{kind}", 'other/other', 'an unknown reason and kind export as other');
        my $m = $n + 3;
        $E->is(join(',', map { $o[$m]{$_} } qw(native plugin_turn plugin_compact compact_min cache_s)), 'vetoed,on,on,200000,600', 'idle_mode vetoed');
        $E->is(join(',', map { $o[$m + 1]{$_} } qw(native plugin_turn plugin_compact)), 'compaction-off,off,off', 'idle_mode compaction-off');
        $E->is(join(',', map { $o[$m + 2]{$_} } qw(native plugin_turn plugin_compact compact_min)), 'on,check,check,300000', 'idle_mode check (lane B)');
        $E->is($o[$m + 3]{plugin_compact}, 'agents', 'idle_mode agents (lane A rows)');
        $E->is($o[$m + 4]{plugin_compact}, 'failed', 'idle_mode failed');
        $E->is("$o[$m + 5]{native}/$o[$m + 5]{plugin_compact}", 'other/other', 'unknown idle_mode values export as other');
        my $c = $m + 6;
        $E->is(join(',', $o[$c]{at}, $o[$c]{late_s}, $b->($o[$c]{adopted})), 'timer,0,false', 'idle_compact at the timer');
        $E->is(join(',', $o[$c + 1]{at}, $o[$c + 1]{late_s}, $b->($o[$c + 1]{adopted})), 'check,30,true', 'idle_compact at the check, adopted');
        $E->is($o[$c + 2]{at}, 'other', 'an unknown at exports as other');
        $E->is(join(',', $o[$c + 3]{why}, $o[$c + 3]{fails}), 'failed,2', 'idle_compact_off');
    },
};

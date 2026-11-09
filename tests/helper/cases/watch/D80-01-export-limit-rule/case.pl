# D-80 (0.1.7, export schema): a limit skip or stop row exports the rule that decided (`rule`, one
# of a fixed list, any other word as `other`) and the plan words Claude Code's environment had
# (`plan`, `tier`, words only); a plugin compaction exports its plan-window shares before and after
# it (`pct_before`, `pct_after`, by window kind); a skip for a cold cache after a keep-warm
# fork-miss exports its why. Rows are given as the watcher reads them (booleans as 1 and 0).
my %got;
my @rows = (
    { ev => 'handoff_skipped', why => 'near-limit', reason => 'idle', ht => undef, kind => 'compact', windows => ['five_hour:95'],
      rule => 'delta', plan => 'max', tier => 'default_claude_max_5x' },
    { ev => 'handoff_skipped', why => 'near-limit', reason => 'idle', ht => undef, kind => 'turn', windows => ['spend_limit:91'], rule => 'option-skip-spend' },
    { ev => 'handoff_skipped', why => 'fork-miss', reason => 'idle', ht => undef, kind => 'check' },
    { ev => 'idle_compact', gap_s => 3240, tokens => 150000, agents => 1, at => 'timer', rule => 'band', plan => 'Pro Plan!', tier => 'x' },
    { ev => 'keep_warm_stop', why => 'near-limit', pings => 1, gap_s => 6000, handover => 1, windows => ['five_hour:93'], rule => 'no-such-rule', plan => 'pro' },
    { ev => 'compacted', nonce => 'a' x 8, skip => undef, tokens_before => 150000, tokens_after => 30000, usage_present => 1, ms => 9000,
      pct_before => { five_hour => 93, seven_day => 30 }, pct_after => { five_hour => 95, seven_day => 31, 'Bad Kind' => 4 } },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-11-09T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        my $f = sub { my ($r, @k) = @_; join(',', map { $r->{$_} // '-' } @k) };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped as a field');
        $E->is($f->($o[0], qw(why kind rule plan tier)), 'near-limit,compact,delta,max,default_claude_max_5x', 'a near-limit skip exports its rule and plan words');
        $E->is($f->($o[1], qw(kind rule plan)), 'turn,option-skip-spend,-', "the idle handoff turn's own option rule");
        $E->is($f->($o[2], qw(why kind)), 'fork-miss,check', 'a skip after a fork-miss exports its why');
        $E->is($f->($o[3], qw(at rule plan tier)), 'timer,band,other,x', 'a band compaction exports rule band; a plan word that is no word exports as other');
        $E->is($f->($o[4], qw(why rule plan)), 'near-limit,other,pro', 'an unknown rule exports as other');
        my $c = sub { my $h = shift; join(',', map { "$_:$h->{$_}" } sort keys %$h) };
        $E->is($c->($o[5]{pct_before}) . '/' . $c->($o[5]{pct_after}), 'five_hour:93,seven_day:30/five_hour:95,other:4,seven_day:31',
               'pct_before and pct_after export by window kind (a kind that is no word as other)');
    },
};

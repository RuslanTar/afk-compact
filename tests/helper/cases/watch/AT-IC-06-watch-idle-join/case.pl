# AT-IC-06, watcher half of the idle join (IC-1 D1; core
# rollup::rows): reconcile writes the idle facts on core's `compaction_boundary` row once the
# boundary row was read, while the PostCompact rollup row says `idle: "unknown"` (or null).
# The watcher's join (rules::join_row, used by the rules, `status` and `watch report`) gives
# such a rollup row the boundary's `idle`, `idle_source` and `idle_gap_s`; a settled rollup
# value is kept; idle never counts as a join_conflict. M-01 on the boundary record reads the
# joined value, and the watch report counts the idle compaction.
my ($na, $nb, $nc) = ('1d1e0001', '1d1e0002', '1d1e0003');
my @roll = (
    T::row('compaction', 10, writer => 'helper', actor => 'main', nonce => $na, id6 => 'aaaaaa', trigger => 'auto',
           idle => 'unknown', idle_source => undef, idle_gap_s => undef, verdict => 'ok', copy => 'saved',
           pre_tokens => 300000),
    T::row('compaction_boundary', 11, writer => 'helper', actor => 'main', nonce => $na, id6 => 'aaaaaa', boundary_uuid => 'b-a',
           pre_tokens => 300000, post_tokens => 30000, duration_ms => 20000, precomputed => \0,
           idle => \1, idle_source => 'notice', idle_gap_s => 3235),
    T::row('compaction', 20, writer => 'helper', actor => 'main', nonce => $nb, id6 => 'bbbbbb', trigger => 'auto',
           idle => undef, verdict => 'ok', copy => 'saved', pre_tokens => 310000),
    T::row('compaction_boundary', 21, writer => 'helper', actor => 'main', nonce => $nb, id6 => 'bbbbbb', boundary_uuid => 'b-b',
           pre_tokens => 310000, idle => \0, idle_source => 'none', idle_gap_s => undef),
    T::row('compaction', 30, writer => 'helper', actor => 'main', nonce => $nc, id6 => 'cccccc', trigger => 'auto',
           idle => 'false', idle_source => 'mod', verdict => 'ok', copy => 'saved', pre_tokens => 320000),
    T::row('compaction_boundary', 31, writer => 'helper', actor => 'main', nonce => $nc, id6 => 'cccccc', boundary_uuid => 'b-c',
           pre_tokens => 320000, idle => \1, idle_source => 'both', idle_gap_s => 900),
);
my %got;
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    files => [ { path => '$WATCH/$SID/compactions.jsonl', jsonl => \@roll } ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::rules;
              require watch::report;
              my $ctx = watch::ctx::init({ sid => $T::SID, watch => $v->{WATCH}, root => $v->{ROOT},
                                           plugin_root => $v->{PLUGIN}, settings => {}, now => $T::BASE + 400 });
              my $S = watch::rules::load_session($ctx);
              $got{S} = $S;
              my @rows = @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID/compactions.jsonl") };
              my ($c) = watch::report::compactions(\@rows);
              $got{report} = { map { $_->{nonce} => $_ } @$c };
              require watch::export;
              $got{probes} = watch::export::_probes($ctx, \@rows);
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $S = $got{S};
        my $a = $S->{rollup}{$na};
        $E->is(watch::report::_idle_word($a->{idle}), 'true', 'unknown rollup idle takes the boundary value');
        $E->is($a->{idle_source}, 'notice', 'idle_source joined');
        $E->is($a->{idle_gap_s}, 3235, 'idle_gap_s joined');
        my $b = $S->{rollup}{$nb};
        $E->is(watch::report::_idle_word($b->{idle}), 'false', 'a null rollup idle takes the boundary value');
        $E->is($b->{idle_source}, 'none', 'idle_source none joined');
        my $c = $S->{rollup}{$nc};
        $E->is($c->{idle}, 'false', 'a settled rollup idle is kept');
        $E->is($c->{idle_source}, 'mod', 'a settled idle_source is kept');
        $E->ok((!$c->{_join_conflict} ? 1 : 0), 'idle is never a join_conflict');
        $E->is($S->{join_conflict}, 0, 'no join_conflict counted');
        my $r = $got{report};
        $E->is($r->{$na}{idle}, 'true', 'watch report reads the joined idle');
        $E->is($r->{$nb}{idle}, 'false', 'watch report: joined false');
        $E->is($r->{$nc}{idle}, 'false', 'watch report: the settled rollup value');
        my $p = $got{probes} || {};
        $E->is(join(',', map { "$_=$p->{idle}{$_}" } sort keys %{ $p->{idle} || {} }), 'false=2,true=1', 'probes.json idle counts read the joined bool');
        $E->is(join(',', map { "$_=$p->{idle_source}{$_}" } sort keys %{ $p->{idle_source} || {} }), 'mod=1,none=1,notice=1', 'probes.json idle_source counts');
    },
};

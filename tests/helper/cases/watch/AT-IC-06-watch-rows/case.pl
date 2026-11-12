# AT-IC-06 / AT-QA-03, watcher half (IC-1 D1, D5; QA-2; the event list as folded on
# 2026-10-22): M-01 `idle` comes from the rollup row (an idle
# compaction arrives as trigger `auto`), on the boundary record with `idle_source`; the IC-1
# row kinds (`handoff_turn_start`/`_end` with reason `idle`, `handoff_skipped {why, reason:
# idle}`, `idle_mismatch`, `resume_remeasured`/`_failed`, `submit_dropped`) and the
# `queue_contract {why}` row are kept in the watcher's row cache (read-only) and exported with
# their enums; a pre-idle skip settles no halt row (A-18) and a pre-idle turn is no
# last-cycle stand-in. The watch report counts idle compactions.
my $n = 'c0060001';
my @skips = qw(triggers-off small-window session-changed busy aborted small ttl-5m near-limit episode published cap);
my @mod = (T::row('dispatch', 9, nonce => $n, trigger => 'auto', channel => 'mod-hook', idle => \1),
           T::row('compacted', 10, nonce => $n, skip => undef),
           T::row('continue', 400, result => 'halt:cap', continues_last_hour => 0),
           (map { T::row('handoff_skipped', 401 + $_, why => $skips[$_], reason => 'idle', ht => undef) } 0 .. $#skips),
           T::row('handoff_turn_start', 500, ht => 'abcd0601', reason => 'idle', turn_id => 'p-9', t0 => 1, gap_s => 1800,
                  max_calls => 34, max_tokens => 64000),
           T::row('handoff_turn_end', 520, handoff_turn => 'published', handoff_ht => 'abcd0601', reason => 'idle',
                  cache_read_share => 0.42, interjected => \0),
           T::row('resume_remeasured', 530, nonce => $n, age_s => 700, ms => 120),
           T::row('resume_remeasure_failed', 531, nonce => $n, age_s => 900),
           T::row('submit_dropped', 532, why => 'session-changed'));
my @classic = (T::row('idle_mismatch', 12, writer => 'helper', nonce => $n),
               T::row('queue_contract', 13, writer => 'helper', why => 'untagged'));
my @roll = (T::row('compaction', 11, writer => 'helper', actor => 'main', nonce => $n, trigger => 'auto', idle => 'true',
                   idle_source => 'notice', idle_gap_s => 1800, verdict => 'ok', channel => 'mod-hook', copy => 'saved'));
my %got;
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 9) },
        { path => '$WATCH/$SID/handoff-turn/abcd0601.json',
          json => { v => 1, ht => 'abcd0601', session_id => $T::SID, reason => 'idle', opened_at => T::loc(405) } },
        { path => '$WATCH/$SID/handoff-turn/abcd0601.published', text => '' },
        { path => '$WATCH/$SID.jsonl', jsonl => \@mod },
        { path => '$WATCH/$SID.classic.jsonl', jsonl => \@classic },
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => \@roll },
    ],
    transcript => [ T::prompt(0), T::boundary(10, trigger => 'auto', preTokens => 300000), T::summary(10.1), T::prompt(20) ],
    steps => [
        { call => 'stop', at => 430 },
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::rules;
              my $ctx = watch::ctx::init({ sid => $T::SID, watch => $v->{WATCH}, root => $v->{ROOT}, plugin_root => $v->{PLUGIN},
                                           settings => {}, now => $T::BASE + 600 });
              my $S = watch::rules::load_session($ctx);
              $got{kinds} = { map { $_ => scalar(watch::rules::rows_of($S, $_)) }
                              qw(handoff_turn_start handoff_turn_end idle_mismatch resume_remeasured resume_remeasure_failed
                                 submit_dropped queue_contract handoff_skipped) };
              $got{a18_first} = scalar grep { ($_->{rule} // '') eq 'A-18' } @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID.alerts.jsonl") };
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{x} = [ map { watch::export::transform_row($_, $X) } @mod, @classic, @roll ];
              $got{dropped} = $X->{dropped};
          } },
        { call => 'stop', at => 700 },
        { call => 'cli', argv => [ 'watch', 'report' ], any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->is($b[0]{idle}, 'true', 'M-01 idle from the rollup on the boundary record');
        $E->is($b[0]{idle_source}, 'notice', 'idle_source carried');
        $E->is($b[0]{trigger}, 'auto', 'an idle compaction is trigger auto');
        $E->is($got{kinds}{$_}, ($_ eq 'handoff_skipped' ? scalar(@skips) : 1), "cache keeps $_ rows") for sort keys %{ $got{kinds} };
        $E->is($got{a18_first}, 0, 'pre-idle skips settle no halt row inside its grace period');
        $E->is(scalar($E->alerts('A-18')), 1, 'A-18 for the halt row once settled by time (the idle turn is no stand-in)');
        my @x = grep { defined } @{ $got{x} };
        my @hs = grep { $_->{ev} eq 'handoff_skipped' } @x;
        $E->is(join(',', map { $_->{why} } @hs), join(',', @skips), 'every idle skip reason exported as itself');
        $E->is(scalar(grep { ($_->{reason} // '') eq 'idle' } @hs), scalar @skips, 'reason idle kept');
        my ($ts) = grep { $_->{ev} eq 'handoff_turn_start' } @x;
        $E->is($ts->{gap_s}, 1800, 'gap_s exported');
        my ($te) = grep { $_->{ev} eq 'handoff_turn_end' } @x;
        $E->is($te->{cache_read_share}, 0.42, 'cache_read_share exported');
        my ($qc) = grep { $_->{ev} eq 'queue_contract' } @x;
        $E->is($qc->{why}, 'untagged', 'queue_contract why exported');
        my ($sd) = grep { $_->{ev} eq 'submit_dropped' } @x;
        $E->is($sd->{why}, 'session-changed', 'submit_dropped why exported');
        my ($rl) = grep { $_->{ev} eq 'compaction' } @x;
        $E->is($rl->{idle_source}, 'notice', 'rollup idle_source exported');
        $E->is(join(',', sort keys %{ $got{dropped} }), '', 'nothing dropped from these rows');
        my @o = $E->outputs;
        my ($path) = $o[0]{stdout} =~ /\AWATCH-REPORT (\S+)/;
        my $md = defined $path ? watch::io::slurp($path) // '' : '';
        $E->ok(($md =~ /^Idle compactions \(the rollup `idle` field\): 1 of 1$/m ? 1 : 0), 'the report counts idle compactions');
    },
};

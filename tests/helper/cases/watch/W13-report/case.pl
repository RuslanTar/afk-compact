# W13 `watch report` (WATCHER-SPEC §10.2, §10.3; W-BETA E; BUILD-ROUND-9 WCH-10): over the live
# <watch> folder the report is written to <watch>/reports/<date>_watch-report.md (a second run
# adds `-2`, nothing is overwritten) with the header, the audit, the §10.3 bar table, per-day
# counts, the to-scale tokens_before histogram with the thresholds, duration percentiles by
# trigger, the verdict mix, friction lines, alerts by rule and the cost line. Lines that need
# the transcript tier say `deferred (derived tier)` and never FAIL. `--export` writes the
# `-export` variant with hashed ids: no raw session id in it. Nothing else under <watch>
# changes.
my $other = '0e0e0e0e-1111-4111-8111-111111111111';
my $files = T::w13_session(n => 3, bad_copy => 2);
push @$files, @{ T::w13_session(n => 2, sid => $other) };
my %got;
{
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; $got{t0} = T::tree($v->{WATCH}) } },
        { call => 'cli', argv => [ 'watch', 'report', '--since', 'all' ], stdout_re => qr/\AWATCH-REPORT \S+\/reports\/2026-10-21_watch-report\.md\n\z/ },
        { call => 'cli', argv => [ 'watch', 'report' ], stdout_re => qr/\AWATCH-REPORT \S+\/reports\/2026-10-21_watch-report-2\.md\n\z/ },
        { call => 'cli', argv => [ 'watch', 'report', '--export' ], stdout_re => qr/\AWATCH-REPORT \S+\/reports\/2026-10-21_watch-report-export\.md\n\z/ },
        { call => 'cli', argv => [ 'watch', 'report', '--bogus' ], exit => 64, any_stdout => 1 },
        { call => 'cli', argv => [ 'watch', 'backfill' ], exit => 64, any_stdout => 1 },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{md} = watch::io::slurp("$v->{WATCH}/reports/2026-10-21_watch-report.md") // '';
              $got{md2} = watch::io::slurp("$v->{WATCH}/reports/2026-10-21_watch-report-2.md") // '';
              $got{ex} = watch::io::slurp("$v->{WATCH}/reports/2026-10-21_watch-report-export.md") // '';
              $got{t1} = T::tree($v->{WATCH});
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $md = $got{md};
        my $has = sub { my ($re, $msg) = @_; $E->ok(($md =~ $re ? 1 : 0), $msg) };
        $has->(qr/^- Sample: 2 sessions, \d+ rows, 5 main compactions, 2 alerts$/m, 'header sample line');
        $has->(qr/^- Claude Code versions: 2\.1\.306$/m, 'versions');
        $has->(qr/^## Audit\n\n- PASS /m, 'the audit passes and comes first');
        $has->(qr/^\| Save gap \| 0 \| 1 \| FAIL \|$/m, 'save gap bar: one missing copy fails');
        $has->(qr/^\| Verdict ok\/ok-trailer, shaped main \| >=90% \| 100% of 5 \| PASS \|$/m, 'verdict bar');
        $has->(qr/^\| Post-compaction calls_to_progress \| median <=3, p90 <=6 \| - \| deferred \(derived tier\) \|$/m, 'transcript tier deferred, not FAIL');
        $has->(qr/^\| Sample \| .* \| 5 main, 2 sessions, 1 chains, 3 nudge-driven, 0 resumes \| FAIL \(extend by 7 days\) \|$/m, 'sample bar');
        $has->(qr/^\| Auto-continue per nudge-driven compaction \| 1, except a logged halt \| 3 continues, 3 nudge-driven, 0 halts \| PASS \|$/m, 'auto-continue bar');
        $has->(qr/^\| Resume block delivered once per main compaction \| 100% \| 5 of 5 \| PASS \|$/m, 'resume bar');
        $has->(qr/^\| 2026-10-21 \| 5 \| 2 \|$/m, 'per-day counts');
        $has->(qr/^ 400K- 450K \| +0 <- target 400000$/m, 'an empty bin keeps the target mark');
        $has->(qr/^ 450K- 500K \| #{40} +2 $/m, 'histogram bars to scale');
        $has->(qr/<- soft_max 600000/, 'soft max mark');
        $has->(qr/<- native_trigger 767000/, 'native mark');
        $has->(qr/^\| plugin \| 3 \| \d+ \| \d+ \|$/m, 'durations by trigger');
        $has->(qr/^ok 5$/m, 'verdict mix');
        $has->(qr/^- FR-01 Silent save miss: save gap 1$/m, 'FR-01');
        $has->(qr/^- FR-14 Guard friction: sleep-poll 2\.5\/1000 calls$/m, 'FR-14 per 1000 calls');
        $has->(qr/^### A-05 \(2\)$/m, 'alerts grouped by rule');
        $has->(qr/^- warn a05-0000aaaa session 1b2c3d4e-000 actor main nonce c0de0001 line 10$/m, 'alert line with key and line ref');
        $has->(qr/^Large compactions \(>=400K\): 2 cold \(est\. about \$4 each\), 3 warm/m, 'cost line');
        $E->is($got{md2}, $got{md}, 'the second run writes the same report beside the first');
        $E->ok((index($got{ex}, '1b2c3d4e') < 0 && index($got{ex}, '0e0e0e0e') < 0 ? 1 : 0), 'no raw session id in the export variant');
        $E->ok(($got{ex} =~ /^- Source: this machine, export variant \(ids hashed\)$/m ? 1 : 0), 'export variant labelled');
        $E->ok(($got{ex} =~ /^- Sample: 2 sessions, \d+ rows, 5 main compactions, 2 alerts$/m ? 1 : 0), 'the export variant has the same counts');
        my ($t0, $t1) = @got{qw(t0 t1)};
        $E->is($t1->{$_}, $t0->{$_}, "unchanged: $_") for sort keys %$t0;
        my @new = sort grep { !exists $t0->{$_} } keys %$t1;
        $E->is(join(',', @new), 'export-salt,install-id,reports/2026-10-21_watch-report-2.md,reports/2026-10-21_watch-report-export.md,reports/2026-10-21_watch-report.md',
               'only the reports, salt and install id are new');
    },
};

# AT-AC-03 (T-TEXT E6 acceptance table, F (watch); needs/fix-to-watch.md 3): a main summary
# whose Resume here status line carries the Acuity field (`Status: … · Acuity: <word> ·
# State: …`) keeps the watcher's shape elements: `resume_here_le5` true (Resume here has 4
# lines) and `step1_present` true. The golden summaries are WP-fix's
# tests/fixtures/summaries/acuity/*.txt when that folder is on the branch; the two inline
# bodies below (the same Resume here forms, watch and unstable) run always.
my $spec = main::spec_for_tests();
my $brand = $T::BRAND;
my $mk = sub {
    my ($acuity, $state, $live) = @_;
    return join("\n", '<summary>', "\x{27EA}$brand v1 n=1a2b3c4d s=main\x{27EB}",
        '# LAB-123 — retry worker drains, one flaky spec open',
        '## Resume here',
        "Status: waiting-job · Acuity: $acuity · State: $state (checkpoint: clean)",
        'Step 1: `bin/test spec/workers/retry_worker_spec.rb:42` — for "make the retry worker drain the queue"',
        "Gate: none · Don't: re-run the full suite before the flaky spec is fixed",
        "Live: $live",
        '## User constraints', 'U-1 "keep the public API unchanged" — scope lib/retry_worker.rb; ask: open',
        '## Decisions and do-not-re-raise', 'D-1 backoff capped at 5 tries — because the rate limit resets in 60 s (user)',
        '## In flight', 'none', '## Live state', 'none beyond git (not checked)', '## Open questions', 'none',
        '## Location', 'worktree example-repo, branch feature/LAB-123-retry', '## Work done and findings',
        'RetryWorker backoff: implemented', '## Evidence', 'Volatile: none', '## Next steps',
        '1. `bin/test spec/workers/retry_worker_spec.rb:42` — done when it passes 5 runs in a row', '</summary>', '');
};
my %bodies = ('inline-watch' => $mk->('watch', 'retry worker implemented', 'job b7f3a1 running'),
              'inline-unstable' => $mk->('unstable', 'half-migrated', 'nothing running known (not checked)'));
utf8::encode($_) for values %bodies;
if (my $d = T::fixture_path('summaries/acuity')) {
    for my $f (grep { /\.txt\z/ } watch::io::list_dir($d)) {
        my $t = watch::io::slurp("$d/$f");
        $t =~ s/\{\{plugin\}\}/$brand/g;
        $bodies{"fixture $f"} = $t;
    }
}
my %got;
{
    steps => [
        { call => 'code', code => sub {
              require watch::shape;
              for my $k (sort keys %bodies) {
                  $got{$k} = watch::shape::metrics(body => $bodies{$k}, spec => $spec, is_main => 1);
              }
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $fx = grep { /\Afixture / } keys %bodies;
        $E->ok(($fx == 0 || $fx >= 2 ? 1 : 0), "fixture summaries read when present ($fx)");
        for my $k (sort keys %got) {
            my $el = $got{$k}{elements} || {};
            $E->ok((ref $el->{resume_here_le5} eq 'SCALAR' && ${ $el->{resume_here_le5} } ? 1 : 0), "$k: resume_here_le5 true");
            $E->ok((ref $el->{step1_present} eq 'SCALAR' && ${ $el->{step1_present} } ? 1 : 0), "$k: step1_present true");
            $E->is($el->{resume_here_lines}, 4, "$k: Resume here has 4 lines");
        }
    },
};

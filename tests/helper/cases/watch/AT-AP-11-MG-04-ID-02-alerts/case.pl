# AT-AP-11 (AP-9), AT-MG-04 (MG-5), AT-ID-02 watcher half (ID-2), 2026-10-23.
# A-12: after the boundary, `git push` (class push) is consented by an approvals_carry row of
# that window listing push; a `kubectl apply` in the same window stays A-12 critical even though
# the row lists deploy (an explicit gate never carries); `git push origin feat/x:main` in the same
# window stays A-12 too (REVIEW-NIGHT-3 R3-15: a push to a protected branch is the protected-push
# gate although the row lists push); a push in a later window with no row
# of its own is A-12 again. A-28: a compaction_cold row, and a handoff turn whose first request
# read 0.2 of its input from the cache at 300K tokens; not at 0.9, not at 50K. A-29: one per
# idle_unshaped row. T-13 keeps the empty-list case.
my @mod = (
    T::row('handoff_turn_start', 4, ht => 'ht000001', reason => 'precompact', t0 => 300000),
    T::row('handoff_turn_end', 5, handoff_ht => 'ht000001', reason => 'precompact', cache_read_share => 0.2),
    T::row('handoff_turn_start', 6, ht => 'ht000002', reason => 'precompact', t0 => 50000),
    T::row('handoff_turn_end', 7, handoff_ht => 'ht000002', reason => 'precompact', cache_read_share => 0.2),
    T::row('handoff_turn_start', 8, ht => 'ht000003', reason => 'idle', t0 => 300000),
    T::row('handoff_turn_end', 9, handoff_ht => 'ht000003', reason => 'idle', cache_read_share => 0.9),
    T::row('compaction_cold', 10.4, nonce => '1d1e0c0b', read_share => 0.1),
);
my @classic = (
    T::row('approvals_carry', 10.5, writer => 'helper', source => 'summary', checked => 1, gate => 0, unchecked => 0,
           classes => [ 'push', 'deploy', 'infra-write' ]),
    T::row('idle_unshaped', 10.6, writer => 'helper', boundary_uuid => 'b-idle-1'),
);
{
    # The driver's spec, plus a deploy class and the spec's gate list, so a gate call is outward here.
    spec => do { my $s = spec_for_tests(); $s->{outward_classes}{deploy} = '\bkubectl\s+apply\b';
                 $s->{explicit_gate_classes} = [qw(deploy env-write infra-write prod-write protected-push)];
                 $s->{protected_branch_re} = '^(main|master|release([/-].+)?)$'; $s },
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_0'), T::result(3, 'toolu_0'),
        T::boundary(10, trigger => 'auto'), T::summary(10.1),
        T::bash(12, 'git push origin feat/x', id => 'toolu_1'), T::result(13, 'toolu_1'),
        T::bash(14, 'kubectl apply -f deploy.yaml', id => 'toolu_2'), T::result(15, 'toolu_2'),
        T::bash(15.2, 'git push origin feat/x:main', id => 'toolu_2b'), T::result(15.4, 'toolu_2b'),
        T::assistant_text(16),
        T::boundary(400, trigger => 'auto'), T::summary(400.1),
        T::bash(402, 'git push origin feat/x', id => 'toolu_3'), T::result(403, 'toolu_3'),
        T::assistant_text(404),
    ],
    files => [ { path => '$WATCH/$SID.jsonl', jsonl => \@mod }, { path => '$WATCH/$SID.classic.jsonl', jsonl => \@classic } ],
    steps => [ { call => 'stop', at => 500 } ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-12');
        my @push = grep { ($_->{evidence}{class} // '') eq 'push' } @a;
        my @gate = grep { ($_->{evidence}{class} // '') =~ /\A(?:deploy|infra-write)\z/ } @a;
        $E->count(\@push, 2, 'A-12 push: the push to main in the first window (protected-push gate) and the later window, which has no approval of its own');
        $E->is(join(',', sort map { $_->{evidence}{call_no} } @push), '1,3', 'the push to main is call 3 of the first window; the later one call 1 after the second boundary');
        $E->ok(scalar(@gate) >= 1, 'A-12 for the kubectl apply although the row lists deploy (gate)');
        $E->ok(!grep({ $_->{severity} ne 'critical' } @a), 'A-12 stays critical');
        my @c = $E->alerts('A-28');
        $E->count(\@c, 2, 'A-28: the cold compaction and the cold handoff turn at 300K');
        $E->is(join(',', sort map { $_->{evidence}{kind} } @c), 'compaction,handoff-turn', 'A-28 kinds');
        $E->ok(!grep({ $_->{severity} ne 'warn' } @c), 'A-28 is a warning');
        my @i = $E->alerts('A-29');
        $E->count(\@i, 1, 'A-29: one per idle_unshaped row');
        $E->ok(@i && $i[0]{severity} eq 'warn', 'A-29 is a warning');
    },
};

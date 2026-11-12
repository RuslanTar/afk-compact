# AT-PB-04 (the add-only protected_branches setting), the watcher half: the sweep reads the
# user's protected_branches beside the spec's protected_branch_re. After the boundary, an
# approvals_carry row lists push. `git push origin feat/x:qa-env` and `…:QA-ENV` (the setting's
# qa-env, lower-cased) are the protected-push gate, so A-12 stays although push is listed;
# `…:qa-other` is consented by the row; `…:main` stays A-12 because the setting's `!main` is
# ignored (no entry removes a shipped branch). AT-AP-11 keeps the case without the setting.
my @classic = (
    T::row('approvals_carry', 10.5, writer => 'helper', source => 'summary', checked => 1, gate => 0, unchecked => 0,
           classes => [ 'push' ]),
);
{
    spec => do { my $s = spec_for_tests();
                 $s->{explicit_gate_classes} = [qw(deploy env-write infra-write prod-write protected-push)];
                 $s->{protected_branch_re} = '^(main|master|release([/-].+)?)$'; $s },
    settings => { protected_branches => 'qa-env;!main' },
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_0'), T::result(3, 'toolu_0'),
        T::boundary(10, trigger => 'auto'), T::summary(10.1),
        T::bash(12, 'git push origin feat/x:qa-env', id => 'toolu_1'), T::result(13, 'toolu_1'),
        T::bash(14, 'git push origin feat/x:qa-other', id => 'toolu_2'), T::result(15, 'toolu_2'),
        T::bash(16, 'git push origin feat/x:main', id => 'toolu_3'), T::result(17, 'toolu_3'),
        T::bash(18, 'git push origin feat/x:QA-ENV', id => 'toolu_4'), T::result(19, 'toolu_4'),
        T::assistant_text(20),
    ],
    files => [ { path => '$WATCH/$SID.classic.jsonl', jsonl => \@classic } ],
    steps => [ { call => 'stop', at => 500 } ],
    expect => sub {
        my ($E) = @_;
        my @push = grep { ($_->{evidence}{class} // '') eq 'push' } $E->alerts('A-12');
        $E->count(\@push, 3, 'A-12 push: qa-env (the setting), main (shipped; !main ignored) and QA-ENV (lower-cased)');
        $E->is(join(',', sort map { $_->{evidence}{call_no} } @push), '1,3,4', 'qa-other (call 2) is consented by the approvals_carry row');
        $E->ok(!grep({ $_->{severity} ne 'critical' } @push), 'A-12 stays critical');
    },
};

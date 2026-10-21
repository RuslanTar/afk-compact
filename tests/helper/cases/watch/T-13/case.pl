# T-13 (WATCH §9): `git push` in call 2 after the boundary with no user row
# and empty approvals_verified -> A-12. A later push after a user prompt is
# consented and raises nothing; the transcript row arrives at a later Stop.
{
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_0'), T::result(3, 'toolu_0'),
        T::boundary(10, trigger => 'auto'), T::summary(10.1),
        T::bash(12, 'git status', id => 'toolu_1'), T::result(13, 'toolu_1'),
        T::bash(14, 'git push origin HEAD # CANARY-TEXT-cmd', id => 'toolu_2'), T::result(15, 'toolu_2'),
        T::assistant_text(16),
    ],
    steps => [
        { call => 'stop', at => 20 },
        { call => 'append', rows => [ T::prompt(30), T::bash(32, 'git push origin HEAD', id => 'toolu_3'),
                                      T::result(33, 'toolu_3'), T::assistant_text(34) ] },
        { call => 'stop', at => 40 },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-12');
        $E->count(\@a, 1, 'one A-12');
        $E->is($a[0]{evidence}{class}, 'push', 'class');
        $E->is($a[0]{evidence}{call_no}, 2, 'call 2 after the boundary');
        $E->is($a[0]{severity}, 'critical', 'critical');
    },
};

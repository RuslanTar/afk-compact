# T-01 (WATCH §9): native auto boundary with the summary 2-3 rows after it,
# behind session_context/date attachments -> summary found by content; trigger auto.
my $ls = T::bash(5, 'ls -la', id => 'toolu_ls');
{
    transcript => [
        T::prompt(0),
        $ls,
        T::result(6, 'toolu_ls'),
        T::boundary(10, trigger => 'auto', preTokens => 520000, postTokens => 41000),
        T::attach(10.1, 'session_context'),
        T::attach(10.2, 'date'),
        T::summary(10.3),
        T::prompt(20),
    ],
    steps => [ { call => 'stop', at => 30 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 1, 'one boundary in the sweep rows');
        $E->is($b[0]{trigger}, 'auto', 'trigger');
        $E->is($b[0]{summary_line}, 7, 'summary found by content at line 7');
        $E->is($b[0]{summary_flags}{compact_summary}, 1, 'isCompactSummary recorded');
        $E->is($b[0]{line}, 4, 'boundary line');
        $E->is($b[0]{pre}, 520000, 'preTokens by key');
    },
};

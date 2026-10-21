# T-03 (WATCH §9): a replaced summary without isCompactSummary or
# preservedSegment -> summary found by content; summary_flags records the absence.
{
    transcript => [
        T::prompt(0),
        T::assistant_text(5),
        T::boundary(10, trigger => 'manual', preservedSegment => undef),
        T::summary(10.1, replaced => 1),
        T::prompt(20),
    ],
    steps => [ { call => 'stop', at => 30 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 1, 'one boundary');
        $E->is($b[0]{summary_line}, 4, 'summary found by content');
        $E->is($b[0]{summary_flags}{compact_summary}, 0, 'isCompactSummary absent');
        $E->is($b[0]{summary_flags}{visible_only}, 0, 'isVisibleInTranscriptOnly absent');
        $E->is($b[0]{preserved_segment}, 0, 'preservedSegment absent');
    },
};

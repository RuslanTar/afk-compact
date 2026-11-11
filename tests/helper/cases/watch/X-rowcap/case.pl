# Rows are <= 4 KB. A row that would exceed the cap is not
# written in part; one `watch_error {stage: <ev>, error_class: row-too-large}`
# row is left instead. Forced here with 300 clutter classes in the spec.
my $spec = main::spec_for_tests();
$spec->{clutter_classes} = { map { sprintf('class_%03d', $_) => "zz$_" } 1 .. 300 };
my $body = "# CANARY-TEXT-topic\n";
{
    spec => $spec,
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->rows('classic', 'postcompact') ], 0, 'no oversized postcompact row');
        my @e = $E->rows('classic', 'watch_error');
        $E->is(join(',', map { "$_->{stage}/$_->{error_class}" } @e), 'postcompact/row-too-large', 'one watch_error row');
    },
};

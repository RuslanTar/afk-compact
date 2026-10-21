# T-05 (WATCH §9): a precompute dispatch never installed. The
# `precompute_not_reused` row is reconcile's (WP-core, MOD-SPEC §5.4) and is
# checked at integration; the watcher's part: it is never a failure (M-19,
# TF decision 9), so no A-17 at any later Stop.
my $n = 'c0c00005';
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 2, trigger => 'precompute') } ],
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        { call => 'hook', event => 'PreCompact', at => 2, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'stop', at => 60 },
        { call => 'append', rows => [ T::prompt(1000), T::assistant_text(1010) ] },
        { call => 'stop', at => 2000 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->alerts('A-17') ], 0, 'precompute never counts as a failure');
        $E->count([ $E->rows('classic', 'precompute_or_failed') ], 1, 'the lone auto PreCompact is precompute_or_failed (info)');
    },
};

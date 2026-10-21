# T-20 (WATCH §9, M-19c, §2 join 2): a precompute PreCompact (auto, no nonce)
# with no PostCompact, then an unshaped plugin compaction 0.7 s later ->
# precompute_or_failed (info), no failed:no-post; the later compaction does not
# time-join to the precompute dispatch; verdict unshaped.
my ($np, $ns) = ('7e7e0020', '7e7e0021');
my $body = "# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$np.json", json => T::dispatch($np, 100, trigger => 'precompute') },
        { path => "\$WATCH/\$SID/dispatch/$ns.json", json => T::dispatch($ns, 100.7, channel => 'mod-self', trigger => 'plugin') },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5),
                    T::boundary(129, trigger => 'manual'), T::summary(129.1), T::prompt(140), T::assistant_text(150) ],
    steps => [
        { call => 'hook', event => 'PreCompact', at => 100, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'hook', event => 'PreCompact', at => 100.7, payload => { trigger => 'manual', custom_instructions => undef } },
        { call => 'hook', event => 'PostCompact', at => 130, payload => { trigger => 'manual', compact_summary => $body },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
        { call => 'stop', at => 160 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->rows('classic', 'precompute_or_failed') ], 1, 'precompute_or_failed info row');
        $E->count([ grep { ($_->{evidence}{failed} // '') eq 'no-post' } $E->alerts('A-17') ], 0, 'no failed:no-post');
        my @b = $E->boundaries;
        $E->is($b[0]{nonce}, $ns, 'joined to the plugin dispatch, not the precompute');
        $E->is($b[0]{join}, 'time', 'a time join');
        $E->is($b[0]{trigger}, 'plugin', 'trigger plugin');
        $E->is($b[0]{verdict}, 'unshaped', 'verdict unshaped (a time join never yields ok)');
    },
};

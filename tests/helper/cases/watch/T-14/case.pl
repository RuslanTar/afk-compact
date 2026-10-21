# T-14 (WATCH §9): a foreign marker header in custom_instructions and in the
# summary -> verdict unshaped (the core detector's verdict, passed through),
# ci_foreign_header true; never ok.
my $foreign = "\xe2\x9f\xaaotherplug v2 n=12345678 s=main\xe2\x9f\xab";
my $body = "$foreign\n# CANARY-TEXT-topic\n## Summary\nCANARY-TEXT-body\n";
{
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'manual'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PreCompact', at => 9,
          payload => { trigger => 'manual', custom_instructions => "$foreign\nCANARY-TEXT-keep the SQL" } },
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'manual', compact_summary => $body },
          ctx => { detect => { verdict => 'unshaped', nonce => undef, scope => undef, marker_line => undef,
                               sentinel_from_end => undef, normalized => $body } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($q) = $E->rows('classic', 'precompact');
        $E->is($q->{ci_foreign_header}, 1, 'foreign header seen');
        $E->is($q->{ci_has_nonce}, 0, 'a foreign header is not our nonce');
        $E->is($q->{ci_nonce}, undef, 'no nonce');
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{verdict}, 'unshaped', 'postcompact verdict');
        $E->ok(defined $p->{arm_fp}, 'unshaped summary gets an arm fingerprint');
        my @b = $E->boundaries;
        $E->is($b[0]{verdict}, 'unshaped', 'never ok');
    },
};

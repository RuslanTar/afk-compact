# T-10 (WATCH §9): a summary with `checked 14:05` and a dispatch without a
# measured block -> fabricated_check_tokens 1; A-04. `listed 14:07` is not
# counted (M-10).
my $n = 'e0e00010';
my $body = T::main_body(nonce => $n, W => ['CANARY-TEXT-work: tested, checked 14:05', 'git log listed 14:07']);
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8, tags => ['auto']) } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'auto'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => $body } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{fabricated_check_tokens}, 1, 'one fabricated check token');
        $E->is($p->{measured}, 0, 'dispatch had no measured block');
        $E->count([ $E->alerts('A-04') ], 1, 'A-04');
        $E->is(($E->alerts('A-04'))[0]{severity}, 'warn', 'A-04 is warn');
    },
};

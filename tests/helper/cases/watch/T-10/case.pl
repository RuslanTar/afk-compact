# T-10 (AT-TS-04): three summaries, each with its own dispatch.
#   a) `checked 14:05` (legacy form), measured:false          -> 1 fabricated token
#   b) `checked 2026-10-21 14:05 +0300`, measured:false        -> 1
#   c) a stamp equal to the measured block's stamp, measured:true -> 0
# A-04 for the first two. `listed 14:07` is never counted (M-10).
my ($na, $nb, $nc) = ('e0e00010', 'e0e00011', 'e0e00012');
my $stamp = '2026-10-21 14:05 +0300';
my $body_a = T::main_body(nonce => $na, W => ['CANARY-TEXT-work: tested, checked 14:05', 'git log listed 14:07']);
my $body_b = T::main_body(nonce => $nb, W => ["CANARY-TEXT-work: tested, checked $stamp", "git log listed 2026-10-21 14:07 +0300"]);
my $body_c = T::main_body(nonce => $nc, W => ["CANARY-TEXT-work: tested, checked $stamp"]);
my $det = sub { my ($n, $b) = @_; return { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1,
                                                       sentinel_from_end => 1, normalized => $b } } };
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$na.json", json => T::dispatch($na, 8, tags => ['auto']) },
        { path => "\$WATCH/\$SID/dispatch/$nb.json", json => T::dispatch($nb, 9, tags => ['auto']) },
        { path => "\$WATCH/\$SID/dispatch/$nc.json", json => T::dispatch($nc, 10, tags => ['auto', 'measured']) },
        { path => "\$WATCH/\$SID/checkpoint/$nc.json",
          json => { measured_block => "Measured facts (2026-10-21T14:05:12+03:00):\ncwd: x\n" } },
    ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'auto'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body_a }, ctx => $det->($na, $body_a) },
        { call => 'hook', event => 'PostCompact', at => 12, payload => { trigger => 'auto', compact_summary => $body_b }, ctx => $det->($nb, $body_b) },
        { call => 'hook', event => 'PostCompact', at => 13, payload => { trigger => 'auto', compact_summary => $body_c }, ctx => $det->($nc, $body_c) },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my %by = map { ($_->{nonce_found} => $_) } $E->rows('classic', 'postcompact');
        $E->is($by{$na}{fabricated_check_tokens}, 1, 'legacy form without a measured block: 1');
        $E->is($by{$na}{measured}, 0, 'a) dispatch had no measured block');
        $E->is($by{$nb}{fabricated_check_tokens}, 1, 'full stamp without a measured block: 1');
        $E->is($by{$nc}{fabricated_check_tokens}, 0, 'the measured block\'s own stamp: 0');
        $E->is($by{$nc}{measured}, 1, 'c) measured');
        $E->is($by{$nc}{measured_stamp}, $stamp, 'measured_stamp: the ISO header turned into a stamp');
        $E->ok(!defined $by{$na}{measured_stamp}, 'no measured_stamp without a measured block');
        my @a04 = $E->alerts('A-04');
        $E->ok(@a04 >= 1, 'A-04 raised');
        $E->is($a04[0]{severity}, 'warn', 'A-04 is warn');
    },
};

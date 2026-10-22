# DP-29 (E-M-15; build round 9 carry-over, watch part): when the mod drops its dispatch because
# a native compaction ran, it logs `compacted {skip: native-ran}` with the nonce. Watch A-17
# (a) and (b) skip such rows: no `skipped:native-ran` alert, and the dispatch, older than
# 15 min, is settled (no `no-after`). Another skip class still raises A-17 (a), and a mod
# dispatch with no `compacted` row at all still raises A-17 (b).
my ($nr, $ns, $nn) = ('d2900001', 'd2900002', 'd2900003');
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$nr.json", json => T::dispatch($nr, 10) },
        { path => "\$WATCH/\$SID/dispatch/$ns.json", json => T::dispatch($ns, 20) },
        { path => "\$WATCH/\$SID/dispatch/$nn.json", json => T::dispatch($nn, 30) },
        { path => '$WATCH/$SID.jsonl',
          jsonl => [ T::row('compacted', 11, nonce => $nr, skip => 'native-ran', tokens_before => undef, ms => 5),
                     T::row('compacted', 21, nonce => $ns, skip => 'next-threw', tokens_before => undef, ms => 5) ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-17');
        my %by = map { (($_->{evidence}{failed} // '') . '|' . ($_->{key}{nonce} // '')) => 1 } @a;
        $E->ok((!grep { ($_->{evidence}{failed} // '') eq 'skipped:native-ran' } @a) ? 1 : 0, 'no A-17 (a) for skip native-ran');
        $E->ok((!$by{"no-after|$nr"} ? 1 : 0), 'no A-17 (b) for the dispatch the native-ran row closed');
        $E->is(scalar(grep { ($_->{evidence}{failed} // '') eq 'skipped:next-threw' } @a), 1, 'another skip class still raises A-17 (a)');
        $E->ok(($by{"no-after|$nn"} ? 1 : 0), 'a dispatch with no compacted row still raises A-17 (b)');
    },
};

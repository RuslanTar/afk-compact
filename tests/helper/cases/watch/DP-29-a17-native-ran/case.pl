# DP-29 (E-M-15; build round 9 carry-over, watch part): when the mod drops its dispatch because
# a native compaction ran, it logs `compacted {skip: native-ran}` with the nonce. Watch A-17
# (a) and (b) skip such rows: no `skipped:native-ran` alert, and the dispatch, older than
# 15 min, is settled (no `no-after`). Another skip class still raises A-17 (a), and a mod
# dispatch with no `compacted` row at all still raises A-17 (b). Headless probe 2026-10-27: a
# dispatch whose call Claude Code rejected as headless (`compact_rejected {error_class:
# headless}`) is settled too; a rejection of another class still raises A-17 (b). So is a
# headless `/compact` the host cannot run (`compact_command {error_class: no-command}`); one that
# failed for another reason still raises A-17 (b). A dispatch the mod dropped because a person's
# turn or prompt came after its record was written (`compacted {skip: user-first}`) is settled
# the same way as native-ran.
my ($nr, $ns, $nn, $nh, $no) = ('d2900001', 'd2900002', 'd2900003', 'd2900004', 'd2900005');
my ($nc, $nf, $nu) = ('d2900006', 'd2900007', 'd2900008');
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$nr.json", json => T::dispatch($nr, 10) },
        { path => "\$WATCH/\$SID/dispatch/$ns.json", json => T::dispatch($ns, 20) },
        { path => "\$WATCH/\$SID/dispatch/$nn.json", json => T::dispatch($nn, 30) },
        { path => "\$WATCH/\$SID/dispatch/$nh.json", json => T::dispatch($nh, 40) },
        { path => "\$WATCH/\$SID/dispatch/$no.json", json => T::dispatch($no, 50) },
        { path => "\$WATCH/\$SID/dispatch/$nc.json", json => T::dispatch($nc, 60) },
        { path => "\$WATCH/\$SID/dispatch/$nf.json", json => T::dispatch($nf, 70) },
        { path => "\$WATCH/\$SID/dispatch/$nu.json", json => T::dispatch($nu, 80) },
        { path => '$WATCH/$SID.jsonl',
          jsonl => [ T::row('compacted', 11, nonce => $nr, skip => 'native-ran', tokens_before => undef, ms => 5),
                     T::row('compacted', 21, nonce => $ns, skip => 'next-threw', tokens_before => undef, ms => 5),
                     T::row('compact_rejected', 41, nonce => $nh, attempt => 1, error_class => 'headless'),
                     T::row('compact_rejected', 51, nonce => $no, attempt => 1, error_class => 'other'),
                     T::row('compact_command', 61, nonce => $nc, result => 'rejected', error_class => 'no-command'),
                     T::row('compact_command', 71, nonce => $nf, result => 'failed', error_class => 'other'),
                     T::row('compacted', 81, nonce => $nu, skip => 'user-first', tokens_before => undef, ms => undef) ] },
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
        $E->ok((!$by{"no-after|$nh"} ? 1 : 0), 'no A-17 (b) for a dispatch rejected as headless');
        $E->ok(($by{"no-after|$no"} ? 1 : 0), 'a dispatch rejected for another reason still raises A-17 (b)');
        $E->ok((!$by{"no-after|$nc"} ? 1 : 0), 'no A-17 (b) for a /compact the host cannot run');
        $E->ok(($by{"no-after|$nf"} ? 1 : 0), 'a /compact that failed for another reason still raises A-17 (b)');
        $E->ok((!grep { ($_->{evidence}{failed} // '') eq 'skipped:user-first' } @a) ? 1 : 0, 'no A-17 (a) for skip user-first');
        $E->ok((!$by{"no-after|$nu"} ? 1 : 0), 'no A-17 (b) for the dispatch the user-first row closed');
    },
};

# W13 `watch audit` (WATCHER-SPEC §10.2 step 1; BUILD-ROUND-9 WCH-10): per session, the swept
# main boundaries equal the main postcompact rows and the rollup rows; every non-precompute
# dispatch has a `compacted` row or an explained failure; no `watch_error` lacks a class.
# Failures print first, exit 1; the report lists the same failures at its top.
my $files = T::w13_session(n => 2);
push @{ $files->[0]{jsonl} }, T::row('postcompact', 2000, writer => 'classic', nonce_found => 'c0de00ff', form => 'main',
                                     verdict => 'ok', summary_chars => 7000),
                              T::row('watch_error', 2001, writer => 'classic', stage => 'stop', error_class => undef);
push @{ $files->[1]{jsonl} }, T::row('dispatch', 2002, nonce => 'c0de00fe', trigger => 'auto', channel => 'mod-hook'),
                              T::row('dispatch', 2003, nonce => 'c0de00fd', trigger => 'precompute', channel => 'mod-hook');
my $clean = '0e0e0e0e-1111-4111-8111-111111111111';
push @$files, @{ T::w13_session(n => 2, sid => $clean) };
{
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'cli', argv => [ 'watch', 'audit' ], exit => 1, any_stdout => 1 },
        { call => 'cli', argv => [ 'watch', 'report' ], any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = $E->outputs;
        my $a = $o[0]{stdout};
        $E->ok(($a =~ /^AUDIT FAIL counts 1b2c3d4e-000: boundaries 2, postcompact 3, rollup 2$/m ? 1 : 0), "count mismatch ($a)");
        $E->ok(($a =~ /^AUDIT FAIL dispatch 1b2c3d4e-000: nonce c0de00fe has no compacted row and no explained failure$/m ? 1 : 0), 'unsettled dispatch');
        $E->ok(($a !~ /c0de00fd/ ? 1 : 0), 'a precompute dispatch is not counted');
        $E->ok(($a =~ /^AUDIT FAIL watch_error 1b2c3d4e-000: a row without a class$/m ? 1 : 0), 'classless watch_error');
        $E->ok(($a !~ /0e0e0e0e/ ? 1 : 0), 'the clean session has no failure');
        $E->ok(($a =~ /\AAUDIT FAIL .*\nAUDIT: FAIL \(3 problems, 2 sessions\)\n\z/s ? 1 : 0), 'failures first, then the summary');
        my ($path) = $o[1]{stdout} =~ /\AWATCH-REPORT (\S+)/;
        my $md = defined $path ? watch::io::slurp($path) // '' : '';
        $E->ok(($md =~ /^## Audit\n\n- FAIL counts /m ? 1 : 0), 'the report lists the audit failures first');
    },
};

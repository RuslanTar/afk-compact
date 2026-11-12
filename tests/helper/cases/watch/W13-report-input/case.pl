# W13 `watch report --input DIR`: a
# `report` bundle's rows/ folder is read by the same code as the live folder. The counts match
# the live report; the transcript-tier lines say `n/a (remote)`, never FAIL; the report is
# printed (no --out) and nothing is written; `--out FILE` writes it there. `watch audit --input`
# passes on the same rows.
my $other = '0e0e0e0e-1111-4111-8111-111111111111';
my $files = T::w13_session(n => 3);
push @$files, @{ T::w13_session(n => 2, sid => $other) };
my %got;
{
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z) = T::zips_in("$v->{TMP}/out");
              my $e = T::zip_entries($z);
              for my $n (grep { m{\Arows/} } keys %$e) { main::write_file("$v->{TMP}/in/$n", $e->{$n}{data}) }
              $got{t0} = T::tree($v->{TMP});
          } },
        { call => 'cli', argv => [ 'watch', 'report', '--input', '$TMP/in' ], any_stdout => 1 },
        { call => 'cli', argv => [ 'watch', 'report', '--input', '$TMP/in/rows', '--out', '$TMP/remote.md' ],
          stdout_re => qr/\AWATCH-REPORT \S+remote\.md\n\z/ },
        { call => 'cli', argv => [ 'watch', 'audit', '--input', '$TMP/in' ], stdout_re => qr/\AAUDIT: PASS \(2 sessions\)\n\z/ },
        { call => 'cli', argv => [ 'watch', 'report', '--input', '$TMP/in', '--export' ], exit => 64, any_stdout => 1 },
        { call => 'cli', argv => [ 'watch', 'report', '--input', '$TMP/nope' ], exit => 64, any_stdout => 1 },
        { call => 'code', code => sub { my ($v) = @_; $got{t1} = T::tree($v->{TMP}) } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = $E->outputs;
        my $md = $o[1]{stdout};
        my $has = sub { my ($re, $msg) = @_; $E->ok(($md =~ $re ? 1 : 0), $msg) };
        $has->(qr/^- Source: export rows \(--input\)$/m, 'source line');
        $has->(qr/^- Sample: 2 sessions, \d+ rows, 5 main compactions, 2 alerts$/m, 'the same counts as live');
        $has->(qr/^\| Post-compaction calls_to_progress \| median <=3, p90 <=6 \| - \| n\/a \(remote\) \|$/m, 'n/a (remote), not FAIL');
        $has->(qr/^\| bg survival, shell and agent \| missing = 0 \| - \| n\/a \(remote\) \|$/m, 'bg survival n/a (remote)');
        $has->(qr/^\| Save gap \| 0 \| 0 \| PASS \|$/m, 'save gap computed from the rows');
        $has->(qr/^### A-05 \(2\)$/m, 'alerts by rule');
        $has->(qr/^- warn a05-0000aaaa session [0-9a-f]{12} actor main nonce c0de0001 line 10$/m, 'hashed session ids, line refs kept');
        my %t0 = %{ $got{t0} };
        my @new = sort grep { !exists $t0{$_} } keys %{ $got{t1} };
        $E->is(join(',', @new), 'remote.md', 'only the --out file is new');
    },
};

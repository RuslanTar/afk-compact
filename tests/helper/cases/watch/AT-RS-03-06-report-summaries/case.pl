# AT-RS-03, AT-RS-04, AT-RS-06 (SPEC-DELTAS RS-2/RS-3; owner xxxxxxxx-19, 2026-10-23: summaries in
# a beta report are opt-in per report, asked each time). "Summaries" are the saved main
# compaction copies (<root>/<repo>/<bucket>/compact/*.md); published handoffs are their own kind
# with their own yes (owner xxxxxxxx-33, RS-5: AT-RS-07-08-report-handoffs).
# - RS-03: `report --dry-run` prints `summaries: <n> available (<KB>)` (main copies within
#   --since; subagent copies and handoffs are not counted) and writes nothing.
# - RS-04: `report --with-summaries`: a copy holding a secret and one holding the home folder are
#   withheld (rule ids only), the clean one ships as summaries/<12 hex>.md; the manifest says
#   with_summaries true, summaries_n 1, summaries_withheld 2; the README says business content
#   is not masked; the output lists each file. `report verify` passes that zip.
# - RS-05 (half): without the flag nothing changes: no summaries/, no with_summaries key, the
#   README's content-free promise (AT-WB-02 is the leak canary for the rest).
# - RS-06: `report verify` fails a zip with summaries/ but no with_summaries, and one with the
#   flag but a summary the manifest does not list.
my $tok = 'xoxb-1234567890abcdef';
my $clean = "---\nkind: compact-summary\n---\n# Retry work\nStep 1: run the retry tests again.\nCLEANSUMMARYTEXT\n";
my $c = '$ROOT/qx/b7/compact';
my %got;
{
    allow_canary => 1,
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('copy', 10, writer => 'classic', nonce => 'f0f00004', result => 'saved', slot => 'main') ] },
        { path => "$c/2026-10-21_10-00-00_5e55a001_c1-c0c0c1.md", text => $clean, mtime => $T::BASE },
        { path => "$c/2026-10-21_10-10-00_5e55a001_c2-c0c0c2.md", text => "# Deploy notes\ntoken $tok\n", mtime => $T::BASE },
        { path => "$c/2026-09-01_10-00-00_5e55a001_c1-c0c0c9.md", text => "# Old work\n", mtime => $T::BASE - 30 * 86400 },
        { path => "$c/subagents/2026-10-21_10-00-00_5e55a001-a1_c1-c0c0c4.md", text => "# Sub\n", mtime => $T::BASE },
        { path => '$ROOT/qx/b7/2026-10-21_10-20-00_5e55a001_handoff.md', text => "# Handoff\n", mtime => $T::BASE },
    ],
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{TMP}/$_") for qw(out0 out1 out2);
              my $p = "$v->{ROOT}/qx/b7/compact/2026-10-21_10-20-00_5e55a001_c3-c0c0c3.md";
              open(my $fh, '>', $p) or die "write $p: $!";
              print $fh "# Paths\nEdited $v->{HOME}/work/app/retry.rb\n";
              close $fh;
              utime($T::BASE, $T::BASE, $p);
          } },
        # RS-03
        { call => 'cli', argv => [ 'report', '--dry-run', '--out', '$TMP/out0' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^summaries: 4 available \(1 KB\)$/m },
        { call => 'cli', argv => [ 'report', '--dry-run', '--since', '7d', '--out', '$TMP/out0' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^summaries: 3 available \(1 KB\)$/m },
        # RS-04
        { call => 'cli', argv => [ 'report', '--with-summaries', '--since', '7d', '--out', '$TMP/out1' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^SUMMARY summaries\/[0-9a-f]{12}\.md \d+ B from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/compact\/2026-10-21_10-00-00_5e55a001_c1-c0c0c1\.md$/m },
        # RS-05 (half)
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out2' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^NOT INCLUDED: conversation text, summaries,/m },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z1) = T::zips_in("$v->{TMP}/out1");
              my ($z2) = T::zips_in("$v->{TMP}/out2");
              $got{n0} = scalar(T::zips_in("$v->{TMP}/out0"));
              $got{e1} = $z1 ? T::zip_entries($z1) : {};
              $got{e2} = $z2 ? T::zip_entries($z2) : {};
              $got{raw1} = $z1 ? watch::io::slurp($z1) : '';
              $got{z1} = $z1;
              # RS-06: the logs-only zip plus a summary; the summaries zip plus one not listed
              require watch::bundle;
              my @plus = ((map { [ $_->{name}, $_->{data} ] } sort { $a->{name} cmp $b->{name} } values %{ $got{e2} }),
                          [ 'summaries/0123456789ab.md', $clean ]);
              my @extra = ((map { [ $_->{name}, $_->{data} ] } sort { $a->{name} cmp $b->{name} } values %{ $got{e1} }),
                           [ 'summaries/ba9876543210.md', $clean ]);
              for my $x ([ 'bad-no-flag.zip', \@plus ], [ 'bad-unlisted.zip', \@extra ]) {
                  open(my $fh, '>:raw', "$v->{TMP}/$x->[0]") or die "write: $!";
                  print $fh watch::bundle::zip($x->[1], $T::BASE);
                  close $fh;
              }
              if ($z1) {
                  open(my $fh, '>:raw', "$v->{TMP}/good.zip") or die "write: $!";
                  print $fh $got{raw1};
                  close $fh;
              }
          } },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/good.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-no-flag.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL summaries without with_summaries: summaries\/0123456789ab\.md$/m },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-unlisted.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL not in manifest: summaries\/ba9876543210\.md$/m },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = $E->outputs;
        my ($dry, $dry7, $with, $plain) = @o[0 .. 3];
        $E->is($got{n0}, 0, 'RS-03: the dry runs wrote no zip');
        $E->ok(($dry->{stdout} !~ /^SUMMARY /m ? 1 : 0), 'RS-03: a dry run without the flag lists no summary file');
        my $out = $with->{stdout} // '';
        $E->ok(($out =~ /^WITHHELD summaries\/[0-9a-f]{12}\.md \(secret: slack-token\) from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/compact\/2026-10-21_10-10-00_5e55a001_c2-c0c0c2\.md$/m ? 1 : 0),
               'RS-04: the secret copy is withheld with its rule id');
        $E->ok(($out =~ /^WITHHELD summaries\/[0-9a-f]{12}\.md \(identity: your names, paths or hosts\) from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/compact\/2026-10-21_10-20-00_5e55a001_c3-c0c0c3\.md$/m ? 1 : 0),
               'RS-04: the copy holding the home folder is withheld (identity)');
        $E->ok(($out =~ /^SUMMARIES: added at your request; .*business content is not masked$/m ? 1 : 0), 'RS-04: the output says business content is not masked');
        $E->ok(($out =~ /^FILES \d+: .*, summaries\/ \(1 files\)$/m ? 1 : 0), 'RS-04: FILES counts the summaries');
        $E->ok((index($out, $tok) < 0 ? 1 : 0), 'RS-04: the secret value is not printed');
        my $e1 = $got{e1};
        my @s = grep { m{\Asummaries/} } sort keys %$e1;
        $E->is(scalar @s, 1, 'RS-04: one summary in the zip');
        $E->ok((@s && $s[0] =~ m{\Asummaries/[0-9a-f]{12}\.md\z} && index($e1->{ $s[0] }{data}, 'CLEANSUMMARYTEXT') >= 0 ? 1 : 0), 'RS-04: it is the clean copy');
        $E->ok((index($got{raw1}, $tok) < 0 && index($got{raw1}, '/work/app/retry.rb') < 0 ? 1 : 0), 'RS-04: no withheld text in the zip');
        $E->ok((index($got{raw1}, '5e55a001_c1') < 0 ? 1 : 0), 'RS-04: no source file name in the zip');
        my $m = eval { watch::json::decode($e1->{'manifest.json'}{data}) } || {};
        $E->is($m->{with_summaries}, 1, 'RS-04: manifest with_summaries true');
        $E->is($m->{summaries_n}, 1, 'RS-04: manifest summaries_n 1');
        $E->is($m->{summaries_withheld}, 2, 'RS-04: manifest summaries_withheld 2');
        my @w = grep { ($_->{file} // '') =~ m{\Asummaries/} } @{ $m->{withheld} || [] };
        $E->is(join(',', sort map { $_->{reason} } @w), 'identity,secret', 'RS-04: withheld reasons');
        $E->ok((!grep { exists $_->{value} || exists $_->{text} } @w) ? 1 : 0, 'RS-04: withheld entries hold no value');
        $E->ok(((grep { $_->{name} eq $s[0] } @{ $m->{files} || [] }) && @s ? 1 : 0), 'RS-04: the summary is listed in the manifest');
        my $readme1 = $e1->{'README.txt'}{data} // '';
        $E->ok(($readme1 =~ /business content is not masked/ ? 1 : 0), 'RS-04: the zip README says business content is not masked');
        my $e2 = $got{e2};
        $E->is(scalar(grep { m{\Asummaries/} } keys %$e2), 0, 'RS-05: no summaries/ without the flag');
        my $m2 = eval { watch::json::decode($e2->{'manifest.json'}{data}) } || {};
        $E->ok((!exists $m2->{with_summaries} && !exists $m2->{summaries_n} ? 1 : 0), 'RS-05: no summaries keys in the manifest');
        $E->ok((($e2->{'README.txt'}{data} // '') =~ /Never inside: conversation text, summaries,/ ? 1 : 0), 'RS-05: README keeps the content-free promise');
        $E->ok((($plain->{stdout} // '') !~ /^(?:summaries:|SUMMARY |SUMMARIES:)/m ? 1 : 0), 'RS-05: no summaries line without --dry-run or the flag');
    },
};

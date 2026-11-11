# AT-RS-07, AT-RS-08 (RS-5, handoffs too: when the
# user agrees to add summaries, the same dialog asks a second, separate yes for published
# handoffs; each kind scanned and withheld on any hit).
# - RS-07: `report --dry-run` prints `handoffs: <n> available (<KB>)` beside the summaries line:
#   top-level bucket files with `kind: handoff` and `writer: handoff` within --since; not a file
#   without frontmatter, another writer's file, an imported copy of a repository export, an
#   export, a summary copy or a symlink. `report --with-handoffs`: a handoff holding a secret, one
#   holding the home folder and one holding a repo folder named like a bundle word (the full
#   identity list, no vocabulary exemption) are withheld (rule ids only), the clean ones ship as
#   handoffs/<12 hex>.md; the manifest says with_handoffs true, handoffs_n 2, handoffs_withheld
#   3 and nothing about summaries; the README and the output say business content is not masked.
#   Each kind needs its own flag: `--with-summaries` alone adds no handoff, both flags add both.
# - RS-08: `report verify` passes those zips and fails a zip with handoffs/ but no
#   with_handoffs (also one with only with_summaries), one with summaries/ under with_handoffs
#   only, one with a handoff the manifest does not list or count, and a bad handoffs/ name.
my $tok = 'xoxb-1234567890abcdef';
my $fm = "---\nkind: handoff\nwriter: handoff\nnonce: 0a0b0c0d\nstatus: in-progress\n---\n";
my $clean = "${fm}# Retry work: tests pass\n## Resume here\nStep 1: rerun the retry tests.\nCLEANHANDOFFTEXT\n";
my $csum = "---\nkind: compact-summary\n---\n# Retry work\nCLEANSUMMARYTEXT\n";
my $b = '$ROOT/qx/b7';
my %got;
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('copy', 10, writer => 'classic', nonce => 'f0f00004', result => 'saved', slot => 'main') ] },
        { path => "$b/2026-10-21_10-00-00_5e55a001_retry.md", text => $clean, mtime => $T::BASE },
        { path => "$b/2026-10-21_10-10-00_5e55a001_deploy.md", text => "${fm}# Deploy\ntoken $tok\n", mtime => $T::BASE },
        { path => "$b/2026-09-01_10-00-00_5e55a001_old.md", text => "${fm}# Old work\n", mtime => $T::BASE - 30 * 86400 },
        { path => "$b/2026-10-21_10-30-00_5e55a001_legacy.md", text => "# Legacy notes\nOTHERTEXT\n", mtime => $T::BASE },
        { path => "$b/2026-10-21_10-40-00_5e55a001_mod.md", text => "---\nkind: handoff\nwriter: mod\n---\n# Mod\nOTHERTEXT\n",
          mtime => $T::BASE },
        { path => "$b/2026-10-21_10-50-00_5e55a001_imported.md",
          text => "---\nkind: handoff\nwriter: handoff\nimported_from: \"repo:docs/handoffs/h.md\"\n---\n# Teammate\nOTHERTEXT\n",
          mtime => $T::BASE },
        { path => "$b/2026-10-21_10-55-00_5e55a001_export.md", text => "---\nkind: handoff\nwriter: handoff\nexport: repo\n---\n# Export\nOTHERTEXT\n",
          mtime => $T::BASE },
        { path => "$b/compact/2026-10-21_10-00-00_5e55a001_c1-c0c0c1.md", text => $csum, mtime => $T::BASE },
        { path => '$ROOT/zz/b9/2026-10-21_11-00-00_5e55a001_other.md', text => $clean =~ s/CLEANHANDOFFTEXT/SECONDCLEANTEXT/r,
          mtime => $T::BASE },
        # a repo folder named like a bundle word (`shadow`): exempt for the rows (E-W-1), but a
        # handoff is free text and is scanned with the full identity list
        { path => '$ROOT/shadow/main/x.md', text => "x\n" },
        { path => "$b/2026-10-21_10-25-00_5e55a001_vocab.md", text => "${fm}# Vocab\nThe shadow run is green.\n", mtime => $T::BASE },
    ],
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{TMP}/$_") for qw(out0 out1 out2 out3);
              my $p = "$v->{ROOT}/qx/b7/2026-10-21_10-20-00_5e55a001_paths.md";
              open(my $fh, '>', $p) or die "write $p: $!";
              print $fh "$fm# Paths\nEdited $v->{HOME}/work/app/retry.rb\n";
              close $fh;
              utime($T::BASE, $T::BASE, $p);
              # a link to a published handoff outside the store is never offered
              my $ext = "$v->{TMP}/elsewhere.md";
              open($fh, '>', $ext) or die "write $ext: $!";
              print $fh "${fm}# Elsewhere\nOTHERTEXT\n";
              close $fh;
              symlink($ext, "$v->{ROOT}/qx/b7/2026-10-21_11-10-00_5e55a001_link.md") or die "symlink: $!";
          } },
        # RS-07: what each kind could add
        { call => 'cli', argv => [ 'report', '--dry-run', '--out', '$TMP/out0' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^summaries: 1 available \(1 KB\)\nhandoffs: 6 available \(1 KB\)$/m },
        { call => 'cli', argv => [ 'report', '--dry-run', '--since', '7d', '--out', '$TMP/out0' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^handoffs: 5 available \(1 KB\)$/m },
        # RS-07: handoffs only
        { call => 'cli', argv => [ 'report', '--with-handoffs', '--since', '7d', '--out', '$TMP/out1' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^HANDOFF handoffs\/[0-9a-f]{12}\.md \d+ B from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/2026-10-21_10-00-00_5e55a001_retry\.md$/m },
        # each kind its own yes: summaries alone, then both
        { call => 'cli', argv => [ 'report', '--with-summaries', '--since', '7d', '--out', '$TMP/out2' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^SUMMARY summaries\//m },
        { call => 'cli', argv => [ 'report', '--with-summaries', '--with-handoffs', '--since', '7d', '--out', '$TMP/out3' ],
          env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/^FILES \d+: .*, summaries\/ \(1 files\), handoffs\/ \(2 files\)$/m },
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::bundle;
              for my $i (0 .. 3) {
                  my ($z) = T::zips_in("$v->{TMP}/out$i");
                  $got{"n$i"} = scalar(T::zips_in("$v->{TMP}/out$i"));
                  $got{"e$i"} = $z ? T::zip_entries($z) : {};
                  $got{"raw$i"} = $z ? watch::io::slurp($z) : '';
                  next unless $z && $i;
                  main::write_file("$v->{TMP}/good$i.zip", $got{"raw$i"}, 0600);
              }
              my $plain = sub { my ($e) = @_; return map { [ $_->{name}, $_->{data} ] } sort { $a->{name} cmp $b->{name} } values %$e };
              my $h = "${fm}# Planted\n";
              my @bad = (
                  # RS-08: a handoff in a summaries-only bundle (not declared)
                  [ 'bad-handoff-in-summaries.zip', [ $plain->($got{e2}), [ 'handoffs/0123456789ab.md', $h ] ] ],
                  # a summary in a handoffs-only bundle
                  [ 'bad-summary-in-handoffs.zip', [ $plain->($got{e1}), [ 'summaries/0123456789ab.md', $csum ] ] ],
                  # a second handoff the manifest neither lists nor counts
                  [ 'bad-unlisted.zip', [ $plain->($got{e1}), [ 'handoffs/ba9876543210.md', $h ] ] ],
                  # a name outside the pattern
                  [ 'bad-name.zip', [ $plain->($got{e1}), [ 'handoffs/notes.md', $h ] ] ],
              );
              for my $x (@bad) { main::write_file("$v->{TMP}/$x->[0]", watch::bundle::zip($x->[1], $T::BASE), 0600) }
              my @rows;
              for my $f (watch::io::list_dir($v->{WATCH})) {
                  next unless $f =~ /\.jsonl\z/;
                  push @rows, grep { ($_->{ev} // '') eq 'report_withheld' } @{ watch::io::read_jsonl("$v->{WATCH}/$f") };
              }
              $got{withheld_rows} = \@rows;
          } },
        # RS-08
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/good1.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/good2.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/good3.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-handoff-in-summaries.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL handoffs without with_handoffs: handoffs\/0123456789ab\.md$/m },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-summary-in-handoffs.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL summaries without with_summaries: summaries\/0123456789ab\.md$/m },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-unlisted.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL manifest: handoffs_n\n(?:.*\n)*VERIFY FAIL not in manifest: handoffs\/ba9876543210\.md$/m },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-name.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL name: handoffs\/notes\.md$/m },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = $E->outputs;
        my ($dry, $dry7, $h1, $s2, $b3) = @o[0 .. 4];
        $E->is($got{n0}, 0, 'RS-07: the dry runs wrote no zip');
        $E->ok((($dry->{stdout} // '') !~ /^(?:HANDOFF|SUMMARY) /m ? 1 : 0), 'RS-07: a dry run lists no file');
        my $out = $h1->{stdout} // '';
        $E->ok(($out =~ /^WITHHELD handoffs\/[0-9a-f]{12}\.md \(secret: slack-token\) from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/2026-10-21_10-10-00_5e55a001_deploy\.md$/m ? 1 : 0),
               'RS-07: the handoff holding a secret is withheld with its rule id');
        $E->ok(($out =~ /^WITHHELD handoffs\/[0-9a-f]{12}\.md \(identity: your names, paths or hosts\) from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/2026-10-21_10-20-00_5e55a001_paths\.md$/m ? 1 : 0),
               'RS-07: the handoff holding the home folder is withheld (identity)');
        $E->ok(($out =~ /^WITHHELD handoffs\/[0-9a-f]{12}\.md \(identity: your names, paths or hosts\) from ~\/\.local\/state\/[^\/]+\/handoffs\/qx\/b7\/2026-10-21_10-25-00_5e55a001_vocab\.md$/m ? 1 : 0),
               'RS-07: the handoff holding a repo folder named like a bundle word is withheld (full identity list)');
        $E->ok(($out =~ /^HANDOFFS: added at your request; .*business content is not masked$/m ? 1 : 0), 'RS-07: the output says business content is not masked');
        $E->ok(($out !~ /^SUMMAR/m ? 1 : 0), 'RS-07: no summary without its own yes');
        $E->ok(($out =~ /^NOT INCLUDED: summaries, settings paths; outside handoffs\/ also conversation text, commands, file paths, repo and branch names$/m ? 1 : 0),
               'RS-07: NOT INCLUDED names summaries');
        $E->ok(($out =~ /^FILES \d+: .*, handoffs\/ \(2 files\)$/m ? 1 : 0), 'RS-07: FILES counts the handoffs');
        $E->ok((index($out, $tok) < 0 ? 1 : 0), 'RS-07: the secret value is not printed');
        my $e1 = $got{e1};
        my @h = grep { m{\Ahandoffs/} } sort keys %$e1;
        $E->is(scalar @h, 2, 'RS-07: two handoffs in the zip (one per bucket)');
        my $hdata = join("\n", map { $e1->{$_}{data} } @h);
        $E->ok((index($hdata, 'CLEANHANDOFFTEXT') >= 0 && index($hdata, 'SECONDCLEANTEXT') >= 0 ? 1 : 0), 'RS-07: they are the clean ones');
        $E->is(scalar(grep { m{\Asummaries/} } keys %$e1), 0, 'RS-07: no summaries/ without --with-summaries');
        my $raw1 = $got{raw1};
        $E->ok((index($raw1, 'OTHERTEXT') < 0 ? 1 : 0), 'RS-07: no legacy, mod, imported, export or linked file in the zip');
        $E->ok((index($raw1, $tok) < 0 && index($raw1, '/work/app/retry.rb') < 0 && index($raw1, 'Old work') < 0 ? 1 : 0),
               'RS-07: no withheld or out-of-window text in the zip');
        $E->ok((index($raw1, '5e55a001_retry') < 0 ? 1 : 0), 'RS-07: no source file name in the zip');
        my $m = eval { watch::json::decode($e1->{'manifest.json'}{data}) } || {};
        $E->is($m->{with_handoffs}, 1, 'RS-07: manifest with_handoffs true');
        $E->is($m->{handoffs_n}, 2, 'RS-07: manifest handoffs_n 2');
        $E->is($m->{handoffs_withheld}, 3, 'RS-07: manifest handoffs_withheld 3');
        $E->is(scalar(grep { ($_->{file} // '') !~ m{\Ahandoffs/} } @{ $m->{withheld} || [] }), 0,
               'RS-07: no rows file withheld for the bundle word (the rows keep the exemption)');
        $E->ok((!exists $m->{with_summaries} && !exists $m->{summaries_n} ? 1 : 0), 'RS-07: no summaries keys in a handoffs-only manifest');
        my @w = grep { ($_->{file} // '') =~ m{\Ahandoffs/} } @{ $m->{withheld} || [] };
        $E->is(join(',', sort map { $_->{reason} } @w), 'identity,identity,secret', 'RS-07: withheld reasons');
        $E->ok(((grep { $_->{name} eq $h[0] } @{ $m->{files} || [] }) && @h ? 1 : 0), 'RS-07: the handoff is listed in the manifest');
        my $readme = $e1->{'README.txt'}{data} // '';
        $E->ok(($readme =~ /^handoffs\/ holds handoffs you chose to add/m && $readme =~ /business content is not masked/
                && $readme =~ /^Outside handoffs\/, never inside: conversation text, summaries, commands,/m ? 1 : 0),
               'RS-07: the zip README names handoffs/ and still promises no summaries');
        $E->is(join(',', sort map { $_->{file_kind} } @{ $got{withheld_rows} || [] }), join(',', ('handoffs') x 6),
               'RS-07: one report_withheld row per withheld handoff and report (two reports with handoffs), kind handoffs');
        # each kind its own yes
        my $e2 = $got{e2};
        $E->is(scalar(grep { m{\Ahandoffs/} } keys %$e2), 0, 'RS-07: --with-summaries adds no handoff');
        $E->is(scalar(grep { m{\Asummaries/} } keys %$e2), 1, 'RS-07: --with-summaries adds the summary');
        $E->ok((index($got{raw2}, 'CLEANHANDOFFTEXT') < 0 ? 1 : 0), 'RS-07: no handoff text in a summaries-only zip');
        my $e3 = $got{e3};
        my $m3 = eval { watch::json::decode($e3->{'manifest.json'}{data}) } || {};
        $E->is(join(',', map { $m3->{$_} // 'null' } qw(with_summaries summaries_n with_handoffs handoffs_n)), '1,1,1,2',
               'RS-07: both flags add both kinds, each counted');
        $E->ok((($b3->{stdout} // '') =~ /^SUMMARIES: added .*\nHANDOFFS: added .*\nNOT INCLUDED: settings paths; outside summaries\/ and handoffs\/ also /m ? 1 : 0),
               'RS-07: both closing lines, NOT INCLUDED for both');
        $E->ok((($e3->{'README.txt'}{data} // '') =~ /^Outside summaries\/ and handoffs\/, never inside: conversation text, commands,/m ? 1 : 0),
               'RS-07: README for both kinds');
    },
};

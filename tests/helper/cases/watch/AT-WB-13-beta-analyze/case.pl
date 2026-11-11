# AT-WB-13, with the analyzer half of
# AT-WB-14: `python3 -I tools/beta-analyze run INBOX --out DIR` over a real `report` bundle and
# its variants. A zip-slip, absolute-name, symlink, oversize (declared in the headers only),
# ratio-bomb, foreign-name, non-zip and symlinked inbox file is refused at intake; a bad hash
# or a pattern hit is quarantined (not extracted); a byte-identical zip is a duplicate and a
# re-sent bundle's rows dedupe; a bundle under the old plugin name is valid. BETA-REPORT.md
# has the per-install and pooled tables and the §G bars, each install gets the `watch report
# --input` report. The analyzer deletes nothing, writes only under DIR, refuses a DIR that is
# not fresh, needs -I, and has no network or delete code. `forget` lists one install's files
# and removes nothing. When tests/fixtures/beta/ is present, its cases.json
# outcomes hold too. 0.1.4 (T-5, T-6): the install's store also holds a sweep row with four shaped
# main compactions (ok, ok-trailer, ok-unclosed, truncated) and a second alert that a later
# alert_closed row closed, so the verdict mix counts ok-unclosed as ok (3 of 4) and the alerts count
# the open ones (as status does), the closed one apart by its reason (still listed, marked closed),
# all read from the exported rows. T-7: the verdicts counted ok are the bundled spec's ok_verdicts (a
# copy of the tool beside a spec listing ok and truncated counts those), the three of 0.1.3 only
# when the spec has no list.
# sha256 through core's sha::hex256 (Digest::SHA when it loads, else the embedded one; the driver loads it)
my $REPO = Cwd::abs_path(File::Basename::dirname(Cwd::abs_path(__FILE__)) . '/../../../../..');
my $TOOL = "$REPO/tools/beta-analyze";
my %got;

my $q = sub { return join(' ', map { "'" . s/'/'\\''/gr . "'" } @_) };
my $run = sub {
    my (@cmd) = @_;
    my $ef = File::Temp->new;
    my $o = `@{[ $q->(@cmd) ]} < /dev/null 2> '@{[ $ef->filename ]}'`;
    return { exit => $? >> 8, out => $o, err => watch::io::slurp($ef->filename) };
};
my $analyze = sub { return $run->('python3', '-I', $TOOL, @_) };

# Rewrite one central-directory entry (and its local header) of a STORE zip.
my $patch = sub {
    my ($z, $name, %f) = @_;
    my $eocd = rindex($z, pack('V', 0x06054b50));
    my (undef, undef, undef, undef, $n, undef, $p) = unpack('VvvvvVV', substr($z, $eocd, 20));
    for (1 .. $n) {
        my ($nlen, $xlen, $clen) = unpack('vvv', substr($z, $p + 28, 6));
        my $loff = unpack('V', substr($z, $p + 42, 4));
        if (substr($z, $p + 46, $nlen) eq $name) {
            substr($z, $p + 4, 2) = pack('v', (3 << 8) | 20) if $f{attr};
            substr($z, $p + 38, 4) = pack('V', $f{attr} << 16) if $f{attr};
            if (defined $f{size}) { substr($z, $p + 24, 4) = pack('V', $f{size}); substr($z, $loff + 22, 4) = pack('V', $f{size}) }
            return $z;
        }
        $p += 46 + $nlen + $xlen + $clen;
    }
    die "patch: no entry $name";
};

my $render_fixtures = sub {
    my ($src, $dst, $brand) = @_;
    my $cases = watch::io::read_json_file("$src/cases.json");
    watch::io::mkdir_p($dst);
    for my $name (sort keys %{ $cases->{zips} }) {
        my $z = watch::io::slurp("$src/$name");
        if ($cases->{zips}{$name}{intake} eq 'accept') {
            my $u = watch::bundle::unzip($z);
            $z = watch::bundle::zip([ map { [ $_->{name}, $_->{data} =~ s/\{\{plugin\}\}/$brand/gr ] } @{ $u->{entries} } ], $T::BASE);
        }
        main::write_file("$dst/$name", $z, 0600);
    }
    return $cases;
};

my $tsv = sub {
    my ($path) = @_;
    my @l = split /\n/, (watch::io::slurp($path) // '');
    my @h = split /\t/, shift(@l) // '';
    return [ map { my @c = split /\t/, $_, -1; my %r; @r{@h} = @c; \%r } @l ];
};

my $files = T::beta_install();
my ($classic) = grep { $_->{path} eq '$WATCH/$SID.classic.jsonl' } @$files;
my @verdicts = qw(ok ok-trailer ok-unclosed truncated);
push @{ $classic->{jsonl} }, T::row('sweep', 37, writer => 'classic', file => "$T::SID.jsonl", from_off => 999, to_off => 1999,
    boundaries => [ map { { line => 10 + $_, uuid => "u-shaped-$_", ts => T::z(20 + $_), trigger => 'auto', pre => 400000,
                            attributed => 'main', channel => 'classic', verdict => $verdicts[$_] } } 0 .. $#verdicts ]);
my ($alog) = grep { $_->{path} eq '$WATCH/$SID.alerts.jsonl' } @$files;
push @{ $alog->{jsonl} },
    T::row('alert', 38, writer => 'classic', alert_id => 'a05-5678abcd', rule => 'A-05', severity => 'warn',
           key => { session_id => $T::SID, actor => 'main', compaction_seq => 1, nonce => 'f0f00001' }, evidence => { line => 3 }),
    T::row('alert_closed', 39, writer => 'classic', alert_id => 'a05-5678abcd', rule => 'A-05', reason => 'superseded: rule changed in 0.1.3');

{
    needs => [q(cmd:python3)], needs_note => q(tools/beta-analyze is a python3 tool),
    allow_canary => 1,
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::bundle;
              my $in = "$v->{TMP}/beta/inbox";
              watch::io::mkdir_p($in);
              my ($zp) = T::zips_in("$v->{TMP}/out");
              my $z = watch::io::slurp($zp);
              my $e = T::zip_entries($zp);
              my @order = ('README.txt', 'manifest.json', grep { $_ ne 'README.txt' && $_ ne 'manifest.json' } sort keys %$e);
              my $m0 = watch::json::decode($e->{'manifest.json'}{data});
              $got{install} = $m0->{install_id};
              my ($rowsf) = grep { m{\Arows/} } @order;
              $got{rows_n} = () = $e->{$rowsf}{data} =~ /\n/g;
              # remake(file, manifest changes, entry changes, fix the manifest hashes, extra entries)
              my $remake = sub {
                  my ($file, $mch, $ech, $rehash, $extra) = @_;
                  my %d = map { $_ => $e->{$_}{data} } @order;
                  $d{$_} = $ech->{$_} for keys %{ $ech || {} };
                  my $m = watch::json::decode($e->{'manifest.json'}{data});
                  $m->{$_} = $mch->{$_} for keys %{ $mch || {} };
                  if ($rehash) {
                      for my $f (@{ $m->{files} }) { $f->{sha256} = sha::hex256($d{ $f->{name} }); $f->{bytes} = length $d{ $f->{name} } }
                  }
                  $d{'manifest.json'} = watch::json::encode($m) . "\n";
                  my $bytes = watch::bundle::zip([ (map { [ $_, $d{$_} ] } @order), @{ $extra || [] } ], $T::BASE);
                  main::write_file("$in/$file", $bytes, 0600) if defined $file;
                  return $bytes;
              };
              main::write_file("$in/good.zip", $z, 0600);
              main::write_file("$in/good-copy.zip", $z, 0600);
              # The re-sent bundle is newer (the manifest's own `YYYY-MM-DD HH:MM +hhmm` stamp, RV-24)
              # and carries a config.json with the B.5 default marks: it is the install's latest.
              $got{created0} = $m0->{created};
              my $cfg = '{"available":true,"keys":{"disposable_keep_days":{"class":"num","clamped":false,"default":false,"value":3},'
                      . '"triggers":{"class":"bool","clamped":false,"default":true,"value":true}}}' . "\n";
              $remake->('good-again.zip', { created => '2030-01-02 01:30 +0300' }, { 'config.json' => $cfg }, 1);
              # The other install sent a bundle from a helper without export classes (config.json as
              # `report` writes it then), whatever this branch's core exports.
              $remake->('old-name.zip', { install_id => 'feedfacefeedface', plugin => 'storewatch', schema => 'storewatch-report/1' },
                        { 'config.json' => qq({"available":false,"why":"no-export-classes"}\n) }, 1);
              $remake->('bad-hash.zip', undef, { 'probes.json' => "{\"smoke\":null}\n" });
              (my $hit = $e->{$rowsf}{data}) =~ s/\n\z/\n{"v":1,"ev":"skip","why":"\/Users\/someone\/x"}\n/;
              $remake->('pattern-hit.zip', undef, { $rowsf => $hit }, 1);
              my $zz = $remake->(undef, undef, undef, 0, [ [ 'zz/escape.txt', "x\n" ] ]);
              main::write_file("$in/zip-slip.zip", $zz =~ s{zz/escape\.txt}{../escape.txt}gr, 0600);
              main::write_file("$in/abs-name.zip", $zz =~ s{zz/escape\.txt}{/z/escape.txt}gr, 0600);
              main::write_file("$in/foreign-name.zip", $remake->(undef, undef, undef, 0, [ [ 'notes.txt', "hi\n" ] ]), 0600);
              main::write_file("$in/symlink.zip", $patch->($z, $rowsf, attr => 0120777), 0600);
              main::write_file("$in/oversize.zip", $patch->($z, $rowsf, size => 60 << 20), 0600);
              main::write_file("$in/ratio-bomb.zip", $patch->($z, 'sizes.json', size => 200 * length($e->{'sizes.json'}{data})), 0600);
              main::write_file("$in/junk.zip", "not a zip\n", 0600);
              symlink("$in/good.zip", "$in/link.zip") or die "symlink: $!";
              main::write_file("$in/notes.md", "ignored\n", 0600);
              $got{in0} = T::tree($in);
              $got{home0} = T::tree($v->{HOME});
              $got{tmp0} = T::tree($v->{TMP});
              my $l = main::cli_launcher();
              my $ana = "$v->{TMP}/beta/ana";
              $got{run} = $analyze->('run', $in, '--out', $ana, '--store', $l);
              $got{in1} = T::tree($in);
              $got{home1} = T::tree($v->{HOME});
              $got{tmp1} = T::tree($v->{TMP});
              $got{md} = watch::io::slurp("$ana/BETA-REPORT.md") // '';
              $got{bundles} = { map { $_->{zip} => $_ } @{ $tsv->("$ana/bundles.tsv") } };
              $got{installs} = $tsv->("$ana/installs.tsv");
              $got{alerts} = $tsv->("$ana/alerts.tsv");
              $got{raw} = [ sort(watch::io::list_dir("$ana/raw")) ];
              $got{inst} = [ sort(watch::io::list_dir("$ana/installs")) ];
              $got{wr} = [ map { -s "$ana/installs/$_/WATCH-REPORT.md" ? 1 : 0 } @{ $got{inst} } ];
              $got{tsvs} = [ map { -f "$ana/$_" ? 1 : 0 } qw(bundles.tsv installs.tsv alerts.tsv config-changed.tsv) ];
              $got{mode} = (stat $ana)[2] & 07777;
              $got{again} = $analyze->('run', $in, '--out', $ana, '--store', $l);
              $got{tmp2} = T::tree($v->{TMP});
              # the default DIR is INBOX/../beta-analysis/<stamp>/, so `forget` finds it there
              $got{dflt} = $analyze->('run', $in, '--store', $l);
              $got{tmp3} = T::tree($v->{TMP});
              $got{forget} = $analyze->('forget', $got{install}, $in);
              $got{forget_bad} = $analyze->('forget', 'nope', $in);
              $got{tmp4} = T::tree($v->{TMP});
              $got{noiso} = $run->('python3', $TOOL, 'run', $in, '--out', "$v->{TMP}/beta/x", '--store', $l);
              $got{nostore} = $analyze->('run', $in, '--out', "$v->{TMP}/beta/y", '--store', "$v->{TMP}/none");
              $got{tmp5} = T::tree($v->{TMP});
              $got{src} = watch::io::slurp($TOOL);
              # 0.1.4 (T-7, review F-4): the verdict mix takes the bundled spec's ok_verdicts, the three
              # of 0.1.3 only without a usable list: the tool copied beside a spec whose list differs
              # from that fallback, and beside one with no list, over the install's bundle alone
              for my $k (qw(list none)) {
                  my $fr = "$v->{TMP}/spec-$k";
                  watch::io::mkdir_p("$fr/tools");
                  watch::io::mkdir_p("$fr/plugin/assets");
                  watch::io::mkdir_p("$fr/inbox");
                  main::write_file("$fr/tools/beta-analyze", watch::io::slurp($TOOL), 0700);
                  main::write_file("$fr/plugin/assets/handoff-spec.json",
                                   watch::json::encode($k eq 'list' ? { ok_verdicts => [ 'ok', 'truncated' ] } : {}) . "\n", 0600);
                  main::write_file("$fr/inbox/good.zip", watch::io::slurp("$in/good.zip"), 0600);
                  my $sr = $run->('python3', '-I', "$fr/tools/beta-analyze", 'run', "$fr/inbox", '--out', "$fr/ana", '--store', $l);
                  $got{"spec_$k"} = { exit => $sr->{exit}, err => $sr->{err}, md => watch::io::slurp("$fr/ana/BETA-REPORT.md") // '' };
              }
              if (-f "$REPO/tests/fixtures/beta/cases.json") {
                  my $fin = "$v->{TMP}/fx/inbox";
                  $got{fx_cases} = $render_fixtures->("$REPO/tests/fixtures/beta", $fin, $T::BRAND);
                  $got{fx_run} = $analyze->('run', $fin, '--out', "$v->{TMP}/fx/ana", '--store', $l);
                  $got{fx} = { map { $_->{zip} => $_ } @{ $tsv->("$v->{TMP}/fx/ana/bundles.tsv") } };
                  # AT-WB-14 on the fixture: good-1.zip rendered under an old plugin name is valid
                  my $fo = "$v->{TMP}/fx-old/inbox";
                  $render_fixtures->("$REPO/tests/fixtures/beta", $fo, 'storewatch');
                  unlink(grep { !m{/good-1\.zip\z} } map { "$fo/$_" } watch::io::list_dir($fo));
                  $got{fx_old_run} = $analyze->('run', $fo, '--out', "$v->{TMP}/fx-old/ana", '--store', $l);
                  $got{fx_old} = { map { $_->{zip} => $_ } @{ $tsv->("$v->{TMP}/fx-old/ana/bundles.tsv") } };
              }
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $r = $got{run};
        $E->is($r->{exit}, 0, "run exit 0 ($r->{err})");
        $E->is($r->{err}, '', 'run stderr empty');
        my $o = $r->{out};
        my $has = sub { my ($s, $re, $msg) = @_; $E->ok(($s =~ $re ? 1 : 0), $msg) };
        $has->($o, qr/^BUNDLES 14: 3 valid, 2 quarantined, 8 refused, 1 duplicate, 0 unverified$/m, "bundle counts ($o)");
        my $kept = 2 * $got{rows_n};
        $has->($o, qr/^INSTALLS 2, ROWS $kept \($got{rows_n} duplicate rows dropped\)$/m, 'rows dedupe across bundles of one install only');
        my %want = ('zip-slip.zip' => qr/\A'\.\.' in name/, 'abs-name.zip' => qr/\Aabsolute name/, 'symlink.zip' => qr/\Asymlink rows\//,
                    'oversize.zip' => qr/\Aentry over 50 MB/, 'ratio-bomb.zip' => qr/\Acompression ratio over 100 sizes\.json/,
                    'foreign-name.zip' => qr/\Aname outside the bundle names notes\.txt/, 'junk.zip' => qr/\Anot a zip/,
                    'link.zip' => qr/\Anot a regular file/);
        for my $zn (sort keys %want) {
            my $b = $got{bundles}{$zn} || {};
            $E->is($b->{status} // '', 'refused', "$zn refused");
            $has->($b->{note} // '', $want{$zn}, "$zn reason ($b->{note})");
            $has->($o, qr/^REFUSED \Q$zn\E \(/m, "$zn REFUSED line");
        }
        $E->is($got{bundles}{'bad-hash.zip'}{status} // '', 'quarantined', 'bad hash quarantined');
        $has->($got{bundles}{'bad-hash.zip'}{note} // '', qr/sha256: probes\.json/, 'bad hash reason');
        $E->is($got{bundles}{'pattern-hit.zip'}{status} // '', 'quarantined', 'pattern hit quarantined');
        $has->($got{bundles}{'pattern-hit.zip'}{note} // '', qr/pattern abs-path: rows\//, 'pattern hit reason');
        $has->($o, qr/^QUARANTINED pattern-hit\.zip \(.*P0/m, 'QUARANTINED line says P0');
        $E->is($got{bundles}{'good.zip'}{status} // '', 'duplicate', 'byte-identical zip is a duplicate');
        $E->is($got{bundles}{$_}{status} // '', 'valid', "$_ valid") for qw(good-copy.zip good-again.zip old-name.zip);
        $E->is(scalar @{ $got{raw} }, 3, 'only the valid bundles are extracted');
        $E->is(join(',', @{ $got{inst} }), join(',', sort($got{install}, 'feedfacefeedface')), 'one folder per install');
        $E->is(join(',', @{ $got{wr} }), '1,1', 'each install has its watch report');
        $E->is(join(',', @{ $got{tsvs} }), '1,1,1,1', 'the TSVs are written');
        $E->is($got{mode}, 0700, 'DIR is 0700');
        my $md = $got{md};
        for my $h ('# Closed beta report', '## Per install', '## Installs by setup', '## cc versions seen', '## OS',
                   '## Runtime', '## Seat state (compactions)', '## Trigger mix and idle share',
                   '## Verdict mix, shaped main compactions', '## tokens_before at main compactions (to scale)',
                   '## Alerts by rule', '## watch_error classes (stage/class)', '## Watcher overhead p95 per hook',
                   '## Config changed from default', '## Notice and watcher off') {
            $has->($md, qr/^\Q$h\E$/m, "BETA-REPORT has $h");
        }
        $has->($md, qr/^## Benefit bars(?: \([^)]*\))?$/m, "BETA-REPORT has ## Benefit bars");
        $has->($md, qr/^- Bundles: 14 \(3 valid, 2 quarantined, 8 refused at intake, 1 duplicate, 0 unverified\)$/m, 'header counts');
        $has->($md, qr/^\| Uptake \| >=3 installs each return >=1 valid bundle \| 2 \| FAIL \|$/m, 'uptake bar');
        $has->($md, qr/^\| Bundle validity \| .* \| 3 of 13 valid, 2 quarantined \| FAIL \|$/m, 'validity bar');
        $has->($md, qr/^\| Ease \| .* \| p95 \d+\.\d s \| PASS; friend answers: owner review \|$/m, 'ease bar from the manifests');
        my $d0 = '?';
        if (($got{created0} // '') =~ /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d) ([+-])(\d\d)(\d\d)\z/) {
            my $t = watch::io::timegm(0, $5, $4, $3, $2 - 1, $1) - ($6 eq '-' ? -1 : 1) * ($7 * 3600 + $8 * 60);
            my @g = gmtime $t;
            $d0 = sprintf('%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3]);
        }
        $has->($md, qr/^- Bundle dates \(created, UTC\): \Q$d0\E \.\. 2030-01-01$/m, "date range from the manifests' own stamps ($got{created0})");
        $has->($md, qr/^\| disposable_keep_days \| 1 \| 1 \|$/m, "config changed from default, from the install's latest bundle");
        $has->($md, qr/^\| triggers \| 0 \| 1 \|$/m, 'a key at its default counts as not changed');
        $has->($md, qr/^- Installs without export classes in config\.json: 1$/m, 'the other install has no export classes');
        $has->($md, qr/^Quarantined bundles are P0 bugs/m, 'quarantine note');
        $has->($md, qr/^\| auto \| \d+ \|$/m, 'trigger mix row');
        $has->($md, qr/^- \Q$got{install}\E [a-z0-9_.:-]+ A-01 critical session [0-9a-f]{12} nonce f0f00001 line 3$/m, 'per-alert line to ask about');
        $has->($md, qr/\| \Q$got{install}\E \| 3 \| /m, 'per-install row counts its bundles (two valid, one duplicate)');
        # T-5: the four shaped main compactions of each install; ok-unclosed is an ok verdict
        $has->($md, qr/^## Verdict mix, shaped main compactions\n\n- 75% ok\/ok-trailer\/ok-unclosed of 8$/m, 'verdict mix: 3 of 4 ok per install, ok-unclosed counted');
        $has->($md, qr/^\| $_ \| 2 \|$/m, "verdict $_ counted once per install") for @verdicts;
        # T-6: the closed A-05 is not an open alert; it is counted by its close reason
        my ($by_rule) = $md =~ /^## Alerts by rule\n\n(.*?)\n\n/ms;
        $E->is($by_rule // '', "| Value | Alerts |\n|---|---|\n| A-01 | 2 |", 'alerts by rule: the open ones only');
        $has->($md, qr/^## Alerts closed, by reason\n\n\| Value \| Alerts \|\n\|---\|---\|\n\| superseded: rule changed in 0\.1\.3 \| 2 \|$/m, 'closed alerts by reason');
        $has->($md, qr/^\| \Q$got{install}\E \|(?: [^|]* \|){9} 1 \|/m, 'per-install alerts: the open one');
        $has->($md, qr/^- \Q$got{install}\E a05-5678abcd A-05 warn session [0-9a-f]{12} nonce f0f00001 line 3 \(closed: superseded: rule changed in 0\.1\.3\)$/m,
               'the closed alert stays in the list to ask about, marked closed with its reason');
        my %st = map { ($_->{alert_id} => $_->{state}) } grep { $_->{install_id} eq $got{install} } @{ $got{alerts} || [] };
        $E->is($st{'a05-5678abcd'} // 'missing', 'closed: superseded: rule changed in 0.1.3', 'alerts.tsv: the closed alert, its state with the reason');
        my @open = grep { $_ ne 'a05-5678abcd' } sort keys %st;
        $E->is(join(',', map { $st{$_} } @open), 'open', 'alerts.tsv: the other alert is open');
        $E->ok(($md !~ m{/U[s]ers/|/h[o]me/} ? 1 : 0), 'no path in BETA-REPORT');
        # deletes nothing, writes only under DIR
        $E->is(watch::json::encode($got{in1}), watch::json::encode($got{in0}), 'INBOX unchanged');
        $E->is(watch::json::encode($got{home1}), watch::json::encode($got{home0}), 'HOME unchanged');
        my @gone = grep { !exists $got{tmp1}{$_} || $got{tmp1}{$_} ne $got{tmp0}{$_} } keys %{ $got{tmp0} };
        $E->is(join(',', @gone), '', 'no file changed or removed');
        my @new = grep { !exists $got{tmp0}{$_} && !m{\Abeta/ana/} } keys %{ $got{tmp1} };
        $E->is(join(',', @new), '', 'new files only under DIR');
        $E->is($got{again}{exit}, 73, 'a DIR that is not empty is refused');
        $has->($got{again}{out}, qr/\AREFUSED: DIR exists and is not an empty folder/, 'refusal line');
        $E->is(watch::json::encode($got{tmp2}), watch::json::encode($got{tmp1}), 'the refused run wrote nothing');
        $E->is($got{dflt}{exit}, 0, 'default DIR run');
        $has->($got{dflt}{out}, qr{^ANALYSIS \S+/beta/beta-analysis/\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d$}m, 'default DIR is INBOX/../beta-analysis/<stamp>');
        # forget lists and removes nothing
        my $f = $got{forget};
        $E->is($f->{exit}, 0, 'forget exit 0');
        $has->($f->{out}, qr/^FILE \S+\/good\.zip$/m, 'forget lists good.zip');
        $has->($f->{out}, qr/^FILE \S+\/good-again\.zip$/m, 'forget lists the re-sent bundle');
        $has->($f->{out}, qr/^FILE \S+\/pattern-hit\.zip$/m, 'forget lists a quarantined bundle of the install too');
        $E->ok(($f->{out} !~ /old-name\.zip|feedface|\/junk\.zip|\/link\.zip/ ? 1 : 0), 'forget lists no other install and no unreadable zip');
        $has->($f->{out}, qr{^FOLDER \S+/installs/\Q$got{install}\E$}m, 'forget lists the install folder');
        $has->($f->{out}, qr{^FOLDER \S+/raw/[0-9a-f]{8}$}m, 'forget lists the raw folders');
        $has->($f->{out}, qr{^MENTIONS \S+/BETA-REPORT\.md$}m, 'forget lists the pooled files');
        $has->($f->{out}, qr/^REMOVED NOTHING/m, 'forget says it removed nothing');
        $E->is($got{forget_bad}{exit}, 64, 'forget with a bad id is a usage error');
        $E->is(watch::json::encode($got{tmp4}), watch::json::encode($got{tmp3}), 'forget changed nothing');
        $E->is($got{noiso}{exit}, 64, 'without -I the tool refuses');
        $E->is($got{nostore}{exit}, 69, 'no store launcher: exit 69');
        $E->is(join(',', sort grep { !exists $got{tmp4}{$_} } keys %{ $got{tmp5} }), '', 'the refused runs wrote nothing');
        # no network, no model, no delete (static)
        my $src = $got{src};
        $E->ok(($src !~ /^\s*(?:import|from)\s+(?:socket|urllib|http|ssl|ftplib|smtplib|asyncio|xmlrpc|telnetlib|poplib|imaplib|webbrowser|requests)\b/m ? 1 : 0), 'no network module');
        $E->ok(($src !~ /\b(?:os|shutil)\.(?:remove|unlink|rmdir|removedirs|rmtree|rename|replace|truncate|system|popen)\s*\(/ ? 1 : 0), 'no delete or shell call');
        my $calls = () = $src =~ /\bsubprocess\.(?:run|Popen|call|check_call|check_output)\(/g;
        $E->is($calls, 1, 'one process call (the store launcher)');
        $E->ok(($src =~ /sys\.addaudithook\(_audit\)/ ? 1 : 0), 'the audit guard is installed');
        $E->ok(($src !~ /\b(?:claude|codex|anthropic|openai)\b/i ? 1 : 0), 'no model client named');
        # 0.1.4 (T-7): the verdict mix counts and names the bundled spec's ok_verdicts (T-5 above checks
        # the shipped spec's output), the three of 0.1.3 only without a list
        for my $k (qw(list none)) {
            my $sr = $got{"spec_$k"} || {};
            $E->is($sr->{exit}, 0, "spec $k: run exit 0 ($sr->{err})");
        }
        $has->($got{spec_list}{md}, qr/^- 50% ok\/truncated of 4$/m, "a spec listing ok and truncated: 2 of the install's 4 shaped compactions ok, by that list");
        $has->($got{spec_none}{md}, qr/^- 75% ok\/ok-trailer\/ok-unclosed of 4$/m, 'a spec with no list: the three of 0.1.3');
        # The fixture zips (tests/fixtures/beta), once that folder is on the branch
        if ($got{fx_cases}) {
            $E->is($got{fx_run}{exit}, 0, "fixture run exit 0 ($got{fx_run}{err})");
            for my $zn (sort keys %{ $got{fx_cases}{zips} }) {
                my $c = $got{fx_cases}{zips}{$zn};
                my $want = $c->{intake} eq 'refuse' ? 'refused' : $c->{verify};
                my $st = $got{fx}{$zn}{status} // '';
                my $dup = $c->{dedupe_with} ? $got{fx}{ $c->{dedupe_with} }{status} // '' : '';
                $E->ok(($st eq $want || ($want eq 'valid' && $st eq 'duplicate') ? 1 : 0), "fixture $zn: $st, want $want");
                $E->ok((($st eq 'duplicate') ^ ($dup eq 'duplicate') ? 1 : 0), "fixture $zn dedupes with $c->{dedupe_with}") if $c->{dedupe_with};
            }
            $E->is($got{fx_old_run}{exit}, 0, "old-name fixture run exit 0 ($got{fx_old_run}{err})");
            $E->is($got{fx_old}{'good-1.zip'}{status}, 'valid', 'AT-WB-14: fixture good-1.zip under an old plugin name is valid');
        }
    },
};

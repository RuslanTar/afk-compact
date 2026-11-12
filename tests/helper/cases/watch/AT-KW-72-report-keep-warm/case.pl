# Keep-warm statistics, 0.1.11 (the report): `watch report` has a `## Keep-warm` section and the
# report zip a `keep-warm.json`, both built from the log rows alone: the gaps armed (warmed and
# refused, refused by reason), the pings sent and how they came back (hit, missed, late, failed),
# the stops by reason, and for each gap the cache result of the next main request after it (the
# first `cache_after_gap` row after the gap's last row and before the next gap), with Claude Code's
# miss reason. A stop row with no start row before it and no `refused` mark (an older version's
# refusal) counts as refused. `watch report --input` over the zip's rows gives the same section.
my $kw = sub { my ($ev, $t, %f) = @_; return T::row($ev, $t, %f) };
my $after = sub {
    my ($t, %f) = @_;
    return T::row('cache_after_gap', $t + 100, writer => 'classic', resp_ts => T::loc($t), input => 3, %f);
};
my @mod = (
    # gap 1: warmed, one warm ping, one late one, stopped missed
    $kw->('keep_warm_start', 3000, jobs => 1, gap_s => 3000, hours => 6, windows => 2, ping_s => 3000),
    $kw->('keep_warm_send', 3000, n => 1, gap_s => 3000, since_s => 3000),
    $kw->('keep_warm_ping', 3005, n => 1, result => 'warm', cache_read => 228161, cache_creation => 9, since_s => 3000, gap_s => 3000, ms => 5000),
    $kw->('keep_warm_send', 6000, n => 2, gap_s => 6000, since_s => 3000),
    $kw->('keep_warm_ping', 6180, n => 2, result => 'late', cache_read => 228161, cache_creation => 9, since_s => 3000, gap_s => 6000, ms => 180000),
    $kw->('keep_warm_stop', 6180, why => 'missed', pings => 2, gap_s => 6180, handover => \0),
    # gap 2: refused, no jobs
    $kw->('keep_warm_stop', 12000, why => 'no-jobs', pings => 0, gap_s => 3000, handover => \0, refused => \1),
    # gap 3: warmed, an API error tried again, then warm; stopped by a turn
    $kw->('keep_warm_start', 16000, jobs => 2, gap_s => 3000, hours => 6, windows => 2, ping_s => 3000),
    $kw->('keep_warm_send', 16000, n => 1, gap_s => 3000, since_s => 3000),
    $kw->('keep_warm_ping', 16001, n => 1, result => 'api-error', since_s => 3000, gap_s => 3000, ms => 900, status => 529),
    $kw->('keep_warm_send', 16060, n => 1, gap_s => 3060, since_s => 3060),
    $kw->('keep_warm_ping', 16065, n => 1, result => 'warm', cache_read => 230000, cache_creation => 9, since_s => 3060, gap_s => 3060, ms => 5000),
    $kw->('keep_warm_stop', 17000, why => 'turn', pings => 1, gap_s => 4000, handover => \0),
    # gap 4: refused near the limit; no main request before the next gap
    $kw->('keep_warm_stop', 20000, why => 'near-limit', pings => 0, gap_s => 3000, handover => \0, refused => \1, windows => ['five_hour:95'], rule => '90'),
    # gap 5: warmed, the ping missed the main prefix
    $kw->('keep_warm_start', 23000, jobs => 1, gap_s => 3000, hours => 6, windows => 2, ping_s => 3000),
    $kw->('keep_warm_send', 23000, n => 1, gap_s => 3000, since_s => 3000),
    $kw->('keep_warm_ping', 23005, n => 1, result => 'fork-miss', cache_read => 25289, cache_creation => 234319, since_s => 3000, gap_s => 3000, ms => 5000),
    $kw->('keep_warm_stop', 23005, why => 'fork-miss', pings => 1, gap_s => 3005, handover => \0),
    # gap 6: an older version's refusal (no refused mark, no start row, pings 0)
    $kw->('keep_warm_stop', 27000, why => 'ttl-5m', pings => 0, gap_s => 3000, handover => \1),
);
my @classic = (
    # a pause before any gap: belongs to none
    $after->(1000, gap_s => 900, result => 'hit', cache_read => 200000, cache_creation => 100, miss_reason => 'none'),
    $after->(9000, gap_s => 6000, result => 'miss', cache_read => 25289, cache_creation => 234319, miss_reason => 'previous_message_not_found', missed_tokens => 234319),
    $after->(13000, gap_s => 4000, result => 'hit', cache_read => 228000, cache_creation => 300, miss_reason => 'none'),
    $after->(17010, gap_s => 4010, result => 'hit', cache_read => 230000, cache_creation => 400, miss_reason => 'none'),
    $after->(25000, gap_s => 5000, result => 'miss', cache_read => 25289, cache_creation => 240000, miss_reason => 'previous_message_not_found', missed_tokens => 240000),
);
my %got;
my $section = qr/^## Keep-warm\n\n(.*?)(?=^## )/ms;
{
    files => [
        { path => '$WATCH/$SID.jsonl', jsonl => \@mod },
        { path => '$WATCH/$SID.classic.jsonl', jsonl => \@classic },
    ],
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/$_") for qw(out in) } },
        { call => 'cli', argv => [ 'watch', 'report', '--out', '$TMP/live.md' ], stdout_re => qr/\AWATCH-REPORT \S+live\.md\n\z/ },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/^FILES \d+: README\.txt, manifest\.json, config\.json, probes\.json, sizes\.json, keep-warm\.json, rows\/ /m },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{md} = watch::io::slurp("$v->{TMP}/live.md") // '';
              my ($z) = T::zips_in("$v->{TMP}/out");
              my $e = $z ? T::zip_entries($z) : {};
              $got{kw} = $e->{'keep-warm.json'} ? watch::json::decode($e->{'keep-warm.json'}{data}) : undef;
              $got{readme} = $e->{'README.txt'} ? $e->{'README.txt'}{data} : '';
              $got{manifest} = $e->{'manifest.json'} ? watch::json::decode($e->{'manifest.json'}{data}) : {};
              for my $n (grep { m{\Arows/} } keys %$e) { main::write_file("$v->{TMP}/in/$n", $e->{$n}{data}) }
              if ($z) {
                  open(my $fh, '>:raw', "$v->{TMP}/good.zip") or die "write: $!";
                  print $fh watch::io::slurp($z);
                  close $fh;
              }
          } },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/good.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'watch', 'report', '--input', '$TMP/in' ], any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = $E->outputs;
        my ($live) = $got{md} =~ $section;
        my ($remote) = ($o[-1]{stdout} // '') =~ $section;
        $E->ok(defined $live ? 1 : 0, 'the live report has a Keep-warm section') or return;
        my $has = sub { my ($re, $msg) = @_; $E->ok(($live =~ $re ? 1 : 0), "$msg ($live)") };
        $has->(qr/^- Gaps: 6 armed: 3 warmed, 3 refused, 0 open$/m, 'gaps armed, warmed and refused');
        $has->(qr/^- Refused, by reason: near-limit 1, no-jobs 1, ttl-5m 1$/m, 'refused by reason, an older refusal too');
        $has->(qr/^- Pings: 5 sent; 2 hit, 1 missed, 1 late, 1 failed$/m, 'pings sent and how they came back');
        $has->(qr/^- Ping results: api-error 1, fork-miss 1, late 1, warm 2$/m, 'ping results by class');
        $has->(qr/^- Stops, by reason: fork-miss 1, missed 1, turn 1$/m, 'stops by reason');
        $has->(qr/^- Next main request after a gap: 2 hit, 2 miss, 0 none, 2 not seen yet$/m, 'the next request after each gap');
        $has->(qr/^- Its cache miss reason: none 2, previous_message_not_found 2$/m, 'Claude Code\'s miss reasons');
        $has->(qr/^\| 1 \| warmed \| 2 \| 1 \| missed \| miss \| 6000 \| 0\.10 \| previous_message_not_found \|$/m, 'gap 1 row');
        $has->(qr/^\| 4 \| refused \| 0 \| 0 \| near-limit \| not seen yet \| - \| - \| - \|$/m, 'gap 4: the next request came after gap 5 began');
        $has->(qr/^\| 6 \| refused \| 0 \| 0 \| ttl-5m \| not seen yet \| - \| - \| - \|$/m, 'gap 6 row');
        $E->is($remote, $live, 'the same section from the zip\'s rows (--input)');
        my $k = $got{kw};
        $E->ok(ref $k eq 'HASH' ? 1 : 0, 'keep-warm.json in the zip') or return;
        $E->is(join(',', map { $k->{gaps}{$_} } qw(armed warmed refused open)), '6,3,3,0', 'json: gaps');
        $E->is(join(',', map { "$_=$k->{refused_by}{$_}" } sort keys %{ $k->{refused_by} }), 'near-limit=1,no-jobs=1,ttl-5m=1', 'json: refused by reason');
        $E->is(join(',', map { $k->{pings}{$_} } qw(sent hit missed late failed)), '5,2,1,1,1', 'json: pings');
        $E->is(join(',', map { "$_=$k->{stops_by}{$_}" } sort keys %{ $k->{stops_by} }), 'fork-miss=1,missed=1,turn=1', 'json: stops by reason');
        $E->is(join(',', map { $k->{next_request}{$_} } qw(hit miss none not_seen)), '2,2,0,2', 'json: the next request');
        my @g = @{ $k->{gap_list} || [] };
        $E->is(join(',', map { $_->{outcome} . ':' . ($_->{why} // '-') . ':' . (ref $_->{next} eq 'HASH' ? "$_->{next}{result}/$_->{next}{miss_reason}" : 'none') } @g),
               'warmed:missed:miss/previous_message_not_found,refused:no-jobs:hit/none,warmed:turn:hit/none,refused:near-limit:none,'
               . 'warmed:fork-miss:miss/previous_message_not_found,refused:ttl-5m:none', 'json: each gap and its next request');
        $E->is(join(',', map { $_->{plugin_version} // '-' } @g[0, 1]), '0.1.0,0.1.0', 'json: the versions of each gap');
        $E->ok((index(watch::json::encode($k), $T::SID) < 0) ? 1 : 0, 'no session id in keep-warm.json');
        $E->ok(($got{readme} =~ /keep-warm\.json/ ? 1 : 0), 'the README names keep-warm.json');
        $E->ok((grep { ($_->{name} // '') eq 'keep-warm.json' } @{ $got{manifest}{files} || [] }) ? 1 : 0, 'the manifest lists it');
    },
};

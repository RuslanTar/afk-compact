# AT-AN-26 (0.1.4 W-17): when the sweep lags behind the hooks, one compaction was two records: the
# PostCompact-only record an earlier Stop made (it took the dispatch) and, at the Stop that swept
# the boundary, a boundary-only record without it. Now the swept boundary joins that record: its
# PostCompact row lies within 120 s after the boundary, so the boundary record carries the
# dispatch's nonce and channel, and A-05 (an auto compaction below the target, no idle dispatch) is
# raised once, not once per record. A second compaction whose PostCompact row came 130 s after its
# boundary stays two records (A-05 twice: the P-only one and the boundary one), as before.
my ($n1, $n2) = ('5e5f0001', '5e5f0002');
my $post = sub { my ($n, $t) = @_;
                 return T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main',
                               verdict => 'ok', trigger => 'auto') };
my $roll = sub { my ($n, $t) = @_;
                 return T::row('compaction', $t, writer => 'helper', actor => 'main', nonce => $n, trigger => 'auto',
                               verdict => 'ok', channel => 'mod-hook', copy => 'saved', pre_tokens => 250000, precomputed => \0) };
my %got;
{
    settings => { native_window_tokens => 800000 },
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n1.json", json => T::dispatch($n1, 99) },
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => T::dispatch($n2, 999) },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only'),
                     $post->($n1, 101), $post->($n2, 1130) ] },
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => [ $roll->($n1, 101), $roll->($n2, 1130) ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        # the hooks ran; the sweep has not reached the boundaries: P-only records take n1 and n2
        { call => 'stop', at => 1400 },
        { call => 'code', code => sub {
              $got{a05_first} = scalar grep { ($_->{rule} // '') eq 'A-05' } @{ watch::io::read_jsonl("$_[0]{WATCH}/$T::SID.alerts.jsonl") };
              my $st = watch::io::read_json_file("$_[0]{WATCH}/$T::SID/offsets/$T::SID.jsonl.off") || {};
              $got{ponly_first} = scalar @{ ref $st->{session}{ponly} eq 'ARRAY' ? $st->{session}{ponly} : [] };
          } },
        { call => 'append', rows => [
              T::boundary(100, uuid => 'b-join-1', trigger => 'auto', preTokens => 250000), T::summary(100.1), T::prompt(900),
              T::boundary(1000, uuid => 'b-far-2', trigger => 'auto', preTokens => 250000), T::summary(1000.1), T::prompt(1300) ] },
        { call => 'stop', at => 2000 },
        { call => 'code', code => sub {
              my $st = watch::io::read_json_file("$_[0]{WATCH}/$T::SID/offsets/$T::SID.jsonl.off") || {};
              $got{ponly_after} = [ map { $_->{n} } @{ ref $st->{session}{ponly} eq 'ARRAY' ? $st->{session}{ponly} : [] } ];
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{a05_first}, 2, 'the first Stop raises A-05 for both P-only records (rollup sizes)');
        $E->is($got{ponly_first}, 2, 'and keeps both P-only records');
        my %b = map { ($_->{uuid} => $_) } $E->boundaries;
        my $j = $b{'b-join-1'} || {};
        $E->is($j->{nonce}, $n1, 'the swept boundary joined its P-only record: its dispatch nonce');
        $E->is($j->{join}, 'nonce', 'joined by the nonce the P-only record took');
        $E->is($j->{channel}, 'mod-hook', 'with that dispatch channel');
        $E->ok(main::Checker::truthy($j->{postcompact}), 'and its PostCompact row');
        my $f = $b{'b-far-2'} || {};
        $E->is($f->{join}, undef, 'a boundary 130 s before its PostCompact row joins nothing');
        my @a = $E->alerts('A-05');
        my %by;
        $by{ $_->{key}{nonce} // 'none' }++ for @a;
        $E->is($by{$n1}, 1, 'the joined compaction raises A-05 once');
        $E->count(\@a, 3, 'three A-05 rows: one for the joined compaction, two for the far one');
        $E->is(join(',', @{ $got{ponly_after} || [] }), $n2, 'the joined P-only record leaves the session state; the far one stays');
    },
};

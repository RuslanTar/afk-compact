# AT-AN-09 (0.1.3 alert noise, review test gap m20): the 120 s idle lookup for a swept boundary
# whose dispatch an earlier P-only record took counts only a main mod dispatch that is not a
# precompute. An idle-marked dispatch on the classic channel (n1), one of a subagent (n2) and an
# idle precompute (n3) each lie within 120 s before a boundary: none makes it idle, so all three
# auto compactions below the target raise A-05.
my ($n1, $n2, $n3) = ('4d4e0001', '4d4e0002', '4d4e0003');
my $post = sub { my ($n, $t) = @_;
                 return T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main',
                               verdict => 'ok', trigger => 'auto') };
my $d = sub { my ($n, $t, %o) = @_; return { %{ T::dispatch($n, $t, %o) }, idle => \1, idle_gap_s => 3230 } };
{
    settings => { native_window_tokens => 800000 },
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n1.json", json => $d->($n1, 99, channel => 'classic') },
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => $d->($n2, 999, agent_id => 'agent-x', actor => 'agent-x') },
        { path => "\$WATCH/\$SID/dispatch/$n3.json", json => $d->($n3, 1499, trigger => 'precompute') },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only'),
                     $post->($n1, 101), $post->($n2, 1001) ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        # the hooks ran; the sweep has not reached the boundaries: P-only records take n1 and n2
        { call => 'stop', at => 1200 },
        { call => 'append', rows => [
              T::boundary(100, trigger => 'auto', preTokens => 250000), T::summary(100.1), T::prompt(900),
              T::boundary(1000, trigger => 'auto', preTokens => 250000), T::summary(1000.1), T::prompt(1400),
              T::boundary(1500, trigger => 'auto', preTokens => 250000), T::summary(1500.1), T::prompt(1600) ] },
        { call => 'stop', at => 2000 },
    ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->count(\@b, 3, 'three boundaries');
        $E->is(join(',', map { $_->{join} // '-' } @b), '-,-,-', 'none joined to a dispatch');
        my @a = sort { $a <=> $b } map { $_->{key}{compaction_seq} } $E->alerts('A-05');
        $E->is(join(',', @a), '1,2,3', 'A-05 for all three');
    },
};

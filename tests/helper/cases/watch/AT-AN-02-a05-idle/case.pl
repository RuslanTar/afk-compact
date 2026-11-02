# AT-AN-02 (0.1.3 alert noise item 3): A-05 skips an idle compaction, which runs on the idle
# timer, not at a size. The mod's dispatch record says idle (`idle: true`): a boundary joined to
# it raises nothing; so does a boundary swept after an earlier Stop already took its PostCompact
# row and dispatch on the P-only path (the sweep lagged behind the hooks in a long transcript:
# 2 of the 9 observed A-05 rows on 0.1.2), by the idle dispatch from 120 s before it. An auto
# compaction below the target with no idle dispatch still raises A-05 (the true case).
my ($n1, $n2) = ('1d1e0001', '1d1e0002');
my $idle = sub { my ($n, $t) = @_; return { %{ T::dispatch($n, $t) }, idle => \1, idle_gap_s => 3230 } };
my $post = sub { my ($n, $t) = @_;
                 return T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main',
                               verdict => 'ok', trigger => 'auto') };
{
    settings => { native_window_tokens => 800000 },
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n1.json", json => $idle->($n1, 99) },
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => $idle->($n2, 1499) },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only'),
                     $post->($n1, 101), $post->($n2, 1501) ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        # the hooks ran; the sweep has not reached the boundary yet: the P-only record takes n1
        { call => 'stop', at => 400 },
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
        $E->is(scalar(grep { ($_->{band_position} // '') eq 'below-target' } @b), 3, 'all three below the target');
        my @a = $E->alerts('A-05');
        $E->count(\@a, 1, 'A-05 only for the compaction with no idle dispatch');
        $E->is($a[0]{key}{compaction_seq}, 2, 'the non-idle compaction') if @a;
        $E->is($a[0]{evidence}{band_position}, 'below-target', 'its band') if @a;
    },
};

# AT-AN-08 (0.1.3 alert noise, review test gap m09): A-05 on the P-only path (the hooks ran, the
# sweep never found the boundary; the band from the rollup's size) skips an idle compaction too:
# its dispatch says idle. The non-idle twin, auto and below the target, still raises A-05.
my ($ni, $nn) = ('3d3e0001', '3d3e0002');
my $post = sub { my ($n, $t) = @_;
                 return T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main',
                               verdict => 'ok', trigger => 'auto') };
my $roll = sub { my ($n, $t) = @_;
                 return T::row('compaction', $t, writer => 'helper', actor => 'main', nonce => $n, id6 => substr($n, 2, 6),
                               trigger => 'auto', idle => 'unknown', verdict => 'ok', copy => 'saved', pre_tokens => 250000) };
{
    settings => { native_window_tokens => 800000 },
    files => [
        { path => "\$WATCH/\$SID/dispatch/$ni.json", json => { %{ T::dispatch($ni, 99) }, idle => \1, idle_gap_s => 3230 } },
        { path => "\$WATCH/\$SID/dispatch/$nn.json", json => { %{ T::dispatch($nn, 499) }, idle => \0 } },
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => [ $roll->($ni, 102), $roll->($nn, 502) ] },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only'),
                     $post->($ni, 101), $post->($nn, 501) ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [ { call => 'stop', at => 2000 } ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-05');
        $E->count(\@a, 1, 'A-05 only for the compaction with no idle dispatch');
        $E->is($a[0]{key}{nonce}, $nn, 'the non-idle one') if @a;
        $E->is($a[0]{evidence}{source}, 'rollup', 'from the rollup size') if @a;
    },
};

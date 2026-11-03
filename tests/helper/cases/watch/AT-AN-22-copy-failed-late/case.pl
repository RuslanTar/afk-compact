# AT-AN-22 (0.1.4 W-12): PostCompact's save failed (the rollup row says `copy: failed:<why>` and the
# stash is kept) and reconcile saved the copy late (a `copy {result: late}` row; reconcile writes no
# second rollup row). The compaction's copy is the late one: no A-01 when the late row is there at
# the Stop (n1), and an A-01 raised before it came (n2) is closed with `resolved: copy saved` at the
# next Stop (the row stays). A failed rollup copy with no later save (n3) still raises A-01.
my @n = ('7a7b0001', '7a7b0002', '7a7b0003');
my $post = sub { my ($n, $t) = @_;
                 return T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main', verdict => 'ok', trigger => 'auto') };
my $roll = sub { my ($n, $t) = @_;
                 return T::row('compaction', $t, writer => 'helper', actor => 'main', nonce => $n, trigger => 'auto', verdict => 'ok',
                               channel => 'mod-hook', copy => 'failed:disk', precomputed => \0) };
my $late = sub { my ($n, $t) = @_;
                 return T::row('copy', $t, writer => 'helper', result => 'late', slot => 'main', nonce => $n, id6 => substr($n, 0, 6),
                               rel_path => "repo/general/compact/x_c1-" . substr($n, 0, 6) . '.md') };
my %got;
{
    files => [
        (map { { path => "\$WATCH/\$SID/dispatch/$n[$_].json", json => T::dispatch($n[$_], 99 + 100 * $_) } } 0 .. 2),
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only'),
                     $post->($n[0], 101), $post->($n[1], 201), $post->($n[2], 301), $late->($n[0], 150) ] },
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => [ map { $roll->($n[$_], 101 + 100 * $_) } 0 .. 2 ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5),
                    map({ (T::boundary(100 + 100 * $_, uuid => "b-cf-$_", trigger => 'auto'), T::summary(100.1 + 100 * $_)) } 0 .. 2),
                    T::prompt(400) ],
    steps => [
        { call => 'stop', at => 500 },
        { call => 'code', code => sub {
              $got{first} = [ map { $_->{key}{nonce} } grep { ($_->{rule} // '') eq 'A-01' && ($_->{ev} // '') eq 'alert' }
                              @{ watch::io::read_jsonl("$_[0]{WATCH}/$T::SID.alerts.jsonl") } ];
          } },
        { call => 'append', path => '$WATCH/$SID.classic.jsonl', rows => [ $late->($n[1], 550) ] },
        { call => 'stop', at => 600 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is(join(',', sort @{ $got{first} || [] }), "$n[1],$n[2]", 'the first Stop: no A-01 for the compaction saved late; A-01 for the two not saved yet');
        my @a = $E->alerts('A-01');
        $E->count(\@a, 2, 'no new A-01 at the next Stop (the rows stay)');
        my %c = map { ($_->{alert_id} => $_->{reason}) } $E->rows('alerts', 'alert_closed');
        my %id = map { ($_->{key}{nonce} => $_->{alert_id}) } @a;
        $E->is($c{ $id{ $n[1] } // '' }, 'resolved: copy saved', "the A-01 whose copy landed late is closed");
        $E->ok(!exists $c{ $id{ $n[2] } // '' }, 'the failed copy with no later save stays open');
        $E->is(($a[0] || {})->{evidence}{copy}, 'failed', 'its copy reads failed');
    },
};

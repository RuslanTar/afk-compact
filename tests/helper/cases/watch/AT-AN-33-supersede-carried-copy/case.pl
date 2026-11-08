# AT-AN-33 (0.1.5 E-1; lib/watch/supersede.pm _a09): the re-check of an older A-09 reads each saved
# copy as its summary had it (watch::hooks::copy_text). Another session's 0.1.3 A-09 says its
# second compaction lost U-2; that compaction's copy holds U-2 again only because the helper carried
# it in (frontmatter `ledger_carried`). The summary did lose it, so the alert stays open; a copy
# whose summary itself kept U-2 (renumbered nothing, carried nothing) still closes its alert.
my $OTHER = '4d4e5f60-0000-4000-8000-00000000c0df';
my ($c1, $c2, $c3) = ('3e3f0201', '3e3f0202', '3e3f0203');
my $aid = sub { watch::alerts::alert_id($_[0], $OTHER, @_[1 .. $#_]) };
my $alert = sub {
    my ($id, $n) = @_;
    my $r = T::row('alert', 2000, writer => 'classic', sid => $OTHER, alert_id => $id, rule => 'A-09', severity => 'critical',
                   key => { session_id => $OTHER, actor => 'main', nonce => $n },
                   evidence => { lost_U => 1, lost_D => 0, lost_X => 0, ledger_src => 'copy' });
    $r->{plugin_version} = '0.1.3';
    return $r;
};
my @old = ($alert->($aid->('A-09', "p:$c2"), $c2), $alert->($aid->('A-09', "p:$c3"), $c3));
my $body = sub { my ($n, $fm, @u) = @_; return "---\nkind: compact-summary\n$fm---\n" . T::main_body(nonce => $n, U => \@u) };
my $rel = sub { "repo/general/compact/2026-10-21_x_c$_[0]-" . substr($_[1], 0, 6) . '.md' };
my $copy = sub { my ($k, $n, $t) = @_; return { %{ T::row('copy', $t, writer => 'classic', result => 'saved', slot => 'main', nonce => $n,
                                                           id6 => substr($n, 0, 6), rel_path => $rel->($k, $n)) }, sid => $OTHER } };
my $pc = sub { my ($n, $t) = @_; return { %{ T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main', verdict => 'ok') },
                                          sid => $OTHER } };
my %got;
{
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    files => [
        { path => "\$WATCH/$OTHER.classic.jsonl",
          jsonl => [ $copy->(1, $c1, 1100), $pc->($c2, 1199), $copy->(2, $c2, 1200), $pc->($c3, 1299), $copy->(3, $c3, 1300) ] },
        { path => '$ROOT/' . $rel->(1, $c1), text => $body->($c1, '', 'U-1 "CANARY-TEXT-keep"', 'U-2 "CANARY-TEXT-two"') },
        # the second summary dropped U-2; its copy holds it again as a carried line
        { path => '$ROOT/' . $rel->(2, $c2), text => $body->($c2, 'ledger_carried: "1 line (U-2); sha256 ' . ('cd' x 32) . "\"\n",
                                                             'U-1 "CANARY-TEXT-keep"', 'U-2 "CANARY-TEXT-two"') },
        # the third summary kept both lines itself
        { path => '$ROOT/' . $rel->(3, $c3), text => $body->($c3, '', 'U-1 "CANARY-TEXT-keep"', 'U-2 "CANARY-TEXT-two"') },
        { path => "\$WATCH/$OTHER.alerts.jsonl", jsonl => \@old },
    ],
    steps => [
        { call => 'stop', at => 3000, ctx => { plugin_version => '0.1.4' } },
        { call => 'code', code => sub {
              $got{closed} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$_[0]{WATCH}/$OTHER.alerts.jsonl") } ];
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my %c = map { ($_->{alert_id} => $_) } @{ $got{closed} || [] };
        $E->ok(!$c{ $aid->('A-09', "p:$c2") }, 'the A-09 whose copy holds the lost line only as a carried line stays open');
        $E->ok($c{ $aid->('A-09', "p:$c3") }, 'the A-09 whose summary itself lost nothing is closed');
    },
};

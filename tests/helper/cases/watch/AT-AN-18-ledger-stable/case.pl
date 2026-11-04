# AT-AN-18 (0.1.4 W-1, the watcher half of the stable ledger): A-09 counts an old U/D/X id as lost only
# when the new ledger has neither the id (an entry, an id carried on another entry line, a
# Superseded/fold line) nor an entry with the same normalised text (id, bullet and trailing check
# stamps dropped, case and spaces folded). A chain of four compactions, each compared with the
# previous saved copy: the second renumbers U-3 to U-7 (reworded only in case, spacing and its
# stamp); the third re-carries U-2's line as U-1 (the ids restarted) and carries U-7 in the id list
# another entry line starts with; none raises A-09 (renumbered and carried are counted on the
# postcompact row). The fourth drops U-1's line, which another entry line only cites (`per U-1`):
# a cite carries nothing, so A-09 critical, lost_U 1.
my @n = map { sprintf('6a6b%04d', $_) } 1 .. 4;
my %U = (1 => ['U-3: keep the queue (checked 2026-10-20 09:00 +0300)', 'U-2 "CANARY-TEXT-old"'],
         2 => ["U-7 \xe2\x80\x94 Keep  the QUEUE [verified 2026-10-21 14:05 +0300]", 'U-2 "CANARY-TEXT-old"'],
         3 => ['U-1 "CANARY-TEXT-old"', 'U-9, U-7: still hold'],
         4 => ['U-9, U-7: still hold (per U-1 the queue stays)']);
my %body = map { $_ => T::main_body(nonce => $n[$_ - 1], U => $U{$_}) } 1 .. 4;
my $rel = sub { sprintf('repo/general/compact/2026-10-21_13-5%d-00_1b2c3d4e_c%d-%s.md', $_[0], $_[0], substr($n[$_[0] - 1], 0, 6)) };
my $copy = sub {
    my ($k, $t) = @_;
    return ({ call => 'code', code => sub { main::write_file("$_[0]{ROOT}/" . $rel->($k), "---\nkind: compact-summary\n---\n$body{$k}", 0400) } },
            { call => 'append', path => '$WATCH/$SID.classic.jsonl',
              rows => [ T::row('copy', $t, writer => 'classic', result => 'saved', slot => 'main', nonce => $n[$k - 1], rel_path => $rel->($k)) ] });
};
my $post = sub {
    my ($k, $t) = @_;
    return { call => 'hook', event => 'PostCompact', at => $t, payload => { trigger => 'auto', compact_summary => $body{$k} },
             ctx => { detect => { verdict => 'ok', nonce => $n[$k - 1], scope => 'main', marker_line => 1, sentinel_from_end => 1,
                                  normalized => $body{$k} } } };
};
{
    files => [ map { { path => "\$WATCH/\$SID/dispatch/$n[$_].json", json => T::dispatch($n[$_], 10 + 100 * $_) } } 0 .. 3 ],
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        $copy->(1, 5),
        $post->(2, 111), $copy->(2, 112),
        $post->(3, 211), $copy->(3, 212),
        $post->(4, 311), $copy->(4, 312),
        { call => 'stop', at => 1000 },
    ],
    expect => sub {
        my ($E) = @_;
        my %p = map { (($_->{nonce_found} // '') => $_->{ledger} || {}) } $E->rows('classic', 'postcompact');
        my $l2 = $p{ $n[1] } || {};
        $E->is(join(' ', map { $l2->{$_} // 'undef' } qw(ledger_src lost_U renumbered carried)), 'copy 0 1 0',
               'the renumbered line: nothing lost, one renumbered');
        my $l3 = $p{ $n[2] } || {};
        $E->is(join(' ', map { $l3->{$_} // 'undef' } qw(lost_U lost_D lost_X renumbered carried)), '0 0 0 1 1',
               "the re-carried line and the id in another entry line's id list: nothing lost");
        my $l4 = $p{ $n[3] } || {};
        $E->is(join(' ', map { $l4->{$_} // 'undef' } qw(lost_U renumbered carried)), '1 0 0', 'the dropped line is lost (a cite does not carry it)');
        my @a = $E->alerts('A-09');
        $E->count(\@a, 1, 'one A-09: the dropped U line');
        $E->is($a[0]{key}{nonce}, $n[3], 'for the fourth compaction') if @a;
        $E->is($a[0]{severity}, 'critical', 'a lost U line is critical') if @a;
        $E->is($a[0]{evidence}{lost_U}, 1, 'lost_U 1') if @a;
        $E->is(join(' ', map { $a[0]{evidence}{$_} // 'undef' } qw(renumbered carried)), '0 0', 'the evidence names renumbered and carried') if @a;
    },
};

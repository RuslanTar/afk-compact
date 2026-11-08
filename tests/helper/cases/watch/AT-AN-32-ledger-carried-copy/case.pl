# AT-AN-32 (0.1.5 E-1, the stable ledger's helper side; lib/watch/hooks.pm copy_text): a saved copy
# can hold ledger lines the helper carried in from the previous copy (frontmatter `ledger_carried`).
# A-09 compares a summary with the previous copy as its summary had it, without those lines, so one
# lost line raises one A-09, not one per later compaction. A chain of three: the second summary drops
# U-2 (A-09 critical, lost_U 1), and its copy carries U-2 back; the third summary is the second's
# ledger again: compared with the second copy's own text it loses nothing, so no second A-09.
my @n = map { sprintf('7a7b%04d', $_) } 1 .. 3;
my %U = (1 => ['U-1 "CANARY-TEXT-keep"', 'U-2 "CANARY-TEXT-two"'],
         2 => ['U-1 "CANARY-TEXT-keep"'],
         3 => ['U-1 "CANARY-TEXT-keep"']);
my %body = map { $_ => T::main_body(nonce => $n[$_ - 1], U => $U{$_}) } 1 .. 3;
# the second copy as the helper saves it: the summary plus the carried U-2 line in its section
my %copy = (%body, 2 => T::main_body(nonce => $n[1], U => [ @{ $U{2} }, 'U-2 "CANARY-TEXT-two"' ]));
my %fm = (2 => 'ledger_carried: "1 line (U-2); sha256 ' . ('ab' x 32) . "\"\n");
my $rel = sub { sprintf('repo/general/compact/2026-10-21_13-5%d-00_1b2c3d4e_c%d-%s.md', $_[0], $_[0], substr($n[$_[0] - 1], 0, 6)) };
my $copy = sub {
    my ($k, $t) = @_;
    return ({ call => 'code', code => sub { main::write_file("$_[0]{ROOT}/" . $rel->($k), "---\nkind: compact-summary\n" . ($fm{$k} // '') . "---\n$copy{$k}", 0400) } },
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
    files => [ map { { path => "\$WATCH/\$SID/dispatch/$n[$_].json", json => T::dispatch($n[$_], 10 + 100 * $_) } } 0 .. 2 ],
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        $copy->(1, 5),
        $post->(2, 111), $copy->(2, 112),
        $post->(3, 211), $copy->(3, 212),
        { call => 'stop', at => 1000 },
    ],
    expect => sub {
        my ($E) = @_;
        my %p = map { (($_->{nonce_found} // '') => $_->{ledger} || {}) } $E->rows('classic', 'postcompact');
        $E->is(join(' ', map { $p{ $n[1] }{$_} // 'undef' } qw(ledger_src lost_U)), 'copy 1', 'the second summary lost U-2');
        $E->is(join(' ', map { $p{ $n[2] }{$_} // 'undef' } qw(ledger_src lost_U lost_D lost_X)), 'copy 0 0 0',
               "the third summary, against the second copy without its carried line: nothing lost");
        my @a = $E->alerts('A-09');
        $E->count(\@a, 1, 'one A-09 for the one lost line');
        $E->is($a[0]{key}{nonce}, $n[1], 'for the second compaction') if @a;
    },
};

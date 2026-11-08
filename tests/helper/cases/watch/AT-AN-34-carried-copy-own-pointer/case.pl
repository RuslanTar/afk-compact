# AT-AN-34 (0.1.5 E-1, the stable ledger's helper side; lib/watch/shape.pm uncarried): the watcher
# reads a copy without the ledger lines the helper carried in, with the reader that chose them
# (ledger::line_ids). A summary's own entry that cites a carried id and names ledger.md (`- D-5: …
# replaces D-2; see ledger.md`) is the summary's line, not a pointer line, so it stays. A chain of
# three: the second summary drops D-2 (A-09), and its copy carries D-2 back; the third drops D-5,
# which the second copy's own text still holds, so a second A-09 is raised for it.
my @n = map { sprintf('7a7c%04d', $_) } 1 .. 3;
my $dash = "\xe2\x80\x94";
my $d2 = "- D-2: retry budget 3 $dash because CANARY-TEXT-gateway caps (user)";
my %D = (1 => [$d2, "- D-5: window 45 s $dash because CANARY-TEXT-vendor asked (agent)"],
         2 => ["- D-5: window 45 s $dash replaces D-2; see ledger.md (agent)"],
         3 => ["- D-6: keep the queue $dash because CANARY-TEXT-reason (agent)"]);
my %body = map { $_ => T::main_body(nonce => $n[$_ - 1], D => $D{$_}) } 1 .. 3;
# the second copy as the helper saves it: the summary plus the carried D-2 line in its section
my %copy = (%body, 2 => T::main_body(nonce => $n[1], D => [ @{ $D{2} }, $d2 ]));
my %fm = (2 => 'ledger_carried: "1 line (D-2); sha256 ' . ('ab' x 32) . "\"\n");
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
        $E->is(join(' ', map { $p{ $n[1] }{$_} // 'undef' } qw(ledger_src lost_D)), 'copy 1', 'the second summary lost D-2');
        $E->is(join(' ', map { $p{ $n[2] }{$_} // 'undef' } qw(ledger_src lost_U lost_D lost_X)), 'copy 0 1 0',
               "the third summary lost D-5, which the second copy's own text holds");
        my @a = $E->alerts('A-09');
        $E->count(\@a, 2, 'one A-09 per lost line');
    },
};

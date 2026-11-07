# AT-AN-35 (0.1.5 E-1, the stable ledger's helper side; lib/watch/shape.pm uncarried): the watcher
# reads a copy's carried lines with the spec's carry tag as characters, as the helper does (the
# JSON reader keeps the tag's ` · ` as bytes). A chain of three with the shipped tag: the first
# summary has D-2, its own line D-9 tagged `[from ab12cd34 · D-2 · …]` and a foreign pointer line
# for X-1 and X-2; the second drops D-2 and the pointer line, and its copy carries both back
# (`ledger_carried: 2 lines (D-2, ab12cd34:X-1, ab12cd34:X-2)`); the third drops D-9. Read without
# its carried lines, the second copy still holds the summary's own D-9 (the tag's D-2 is the other
# chain's) and no longer holds the carried pointer line: the third summary lost D-9, not X-1.
my @n = map { sprintf('7a7d%04d', $_) } 1 .. 3;
my $dash = "\xe2\x80\x94";
my $mid = "\xc2\xb7";
my $d2 = "- D-2: retry budget 3 $dash because CANARY-TEXT-gateway caps (user)";
my $d9 = "- D-9: keep port 8080 $dash because CANARY-TEXT-ops (agent) [from ab12cd34 $mid D-2 $mid 2026-10-21 09:14 +0300]";
my $ptr = "- X-1, X-2 moved to evidence/2026-10-20_10-00-00_ab12cd34_x/ledger.md [from ab12cd34 $mid - $mid 2026-10-21 09:14 +0300]";
my %D = (1 => [$d2, $d9, $ptr],
         2 => [$d9],
         3 => ["- D-6: keep the queue $dash because CANARY-TEXT-reason (agent)"]);
my %body = map { $_ => T::main_body(nonce => $n[$_ - 1], D => $D{$_}) } 1 .. 3;
# the second copy as the helper saves it: the summary plus the carried lines in their section
my %copy = (%body, 2 => T::main_body(nonce => $n[1], D => [ @{ $D{2} }, $d2, $ptr ]));
my %fm = (2 => 'ledger_carried: "2 lines (D-2, ab12cd34:X-1, ab12cd34:X-2); sha256 ' . ('ab' x 32) . "\"\n");
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
    # the shipped carry tag (handoff-spec.json carry.tag_re), as bytes, as the watcher reads the file
    spec => { %{ main::spec_for_tests() }, carry => { tag_re => "\\[from [0-9a-f]{8} $mid ([UDX]-[0-9]+|-) $mid [^\\]]+\\]" } },
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
        $E->is(join(' ', map { $p{ $n[1] }{$_} // 'undef' } qw(ledger_src lost_X)), 'copy 1', 'the second summary lost the pointer line');
        $E->is(join(' ', map { $p{ $n[2] }{$_} // 'undef' } qw(ledger_src lost_U lost_D lost_X)), 'copy 0 1 0',
               "the third summary lost D-9, which the second copy's own text holds, and not the carried pointer line");
        my @a = $E->alerts('A-09');
        $E->count(\@a, 2, 'one A-09 per summary that lost a line');
    },
};

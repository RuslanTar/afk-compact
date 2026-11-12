# AT-ST-08, watcher reader: after a reconcile fill
# renamed a `sub-unknown` copy, the watcher's copy-path join takes the newest
# `copy_attributed` row for the copy's id6 over the `copy` row: the previous summary of a
# subagent chain is read from the new name (the old one is gone). The actor join takes the
# attributed agent over `unattributed` for a P-only compaction, so a main marker in that
# summary is a scope leak (A-03). Read-only: no row of core's kinds is written.
my ($n1, $n2, $n3) = ('f0f00021', 'f0f00022', 'f0f00023');
my $agent = 'a5e55a005f5000005';
my $prev = "---\nkind: compact-summary\nactor: $agent\n---\n"
         . T::main_body(nonce => $n1, scope => 'sub', D => ['D-7 keep the cache ' . "\xe2\x80\x94" . ' because CANARY-TEXT-a',
                                                            'D-9 stay on main ' . "\xe2\x80\x94" . ' because CANARY-TEXT-c']);
my $cur = T::main_body(nonce => $n2, scope => 'sub', D => ['D-9 stay on main ' . "\xe2\x80\x94" . ' because CANARY-TEXT-c']);
my $old = 'repo/general/compact/subagents/2026-10-21_13-50-00_1b2c3d4e_c1-f0f000.md';
my $new = 'repo/general/compact/subagents/2026-10-21_13-50-00_1b2c3d4e-aa5e55a00_c1-f0f000.md';
my $leak = "# CANARY-TEXT-topic\n## Resume here\nCANARY-TEXT-body\n";
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => T::dispatch($n2, 8, actor => 'sub', agent_id => $agent) },
        { path => "\$ROOT/$new", text => $prev, mode => 0400 },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('copy', -600, writer => 'classic', result => 'saved', slot => 'subagents', nonce => $n1,
                            id6 => 'f0f000', rel_path => $old),
                     T::row('copy_attributed', -300, writer => 'helper', id6 => 'f0f000', nonce => $n1, from_rel => $old,
                            rel_path => $new, actor => $agent, proof => 'a', seq => 1, pre_tokens => 90000, post_tokens => 9000),
                     T::row('postcompact', 40, writer => 'classic', nonce_found => $n3, scope_found => 'main',
                            verdict => 'ok', trigger => 'auto'),
                     T::row('copy_attributed', 45, writer => 'helper', id6 => 'f0f003', nonce => $n3,
                            rel_path => 'repo/general/compact/subagents/x-aa5e55a00_c2-f0f003.md', actor => $agent,
                            proof => 'a', seq => 2, pre_tokens => 80000, post_tokens => 8000) ] },
        { path => '$WATCH/$SID/compactions.jsonl',
          jsonl => [ T::row('compaction', 41, writer => 'helper', nonce => $n3, id6 => 'f0f003', actor => 'sub-unknown',
                            copy => 'saved') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $cur },
          ctx => { detect => { verdict => 'ok', nonce => $n2, scope => 'sub', marker_line => 1, sentinel_from_end => 1,
                               normalized => $cur } } },
        { call => 'stop', at => 400 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($p) = grep { ($_->{nonce_found} // '') eq $n2 } $E->rows('classic', 'postcompact');
        $E->ok(($p ? 1 : 0), 'postcompact row for the subagent compaction') or return;
        $E->is($p->{ledger}{ledger_src}, 'copy', 'previous summary read from the attributed (renamed) copy');
        $E->is($p->{ledger}{lost_D}, 1, 'D-7 lost against the renamed copy');
        my @a3 = grep { ($_->{key}{nonce} // '') eq $n3 } $E->alerts('A-03');
        $E->count(\@a3, 1, 'A-03: the attributed agent compaction carried a main marker');
        $E->is($a3[0]{key}{actor}, $agent, 'the alert key names the attributed agent') if @a3;
        my %planted = (copy_attributed => 2, stash_kept => 0, stash_dropped => 0, orphan_finished => 0);
        for my $ev (sort keys %planted) {
            $E->count([ $E->rows('classic', $ev) ], $planted{$ev}, "only the planted $ev rows (the watcher writes none)");
        }
    },
};

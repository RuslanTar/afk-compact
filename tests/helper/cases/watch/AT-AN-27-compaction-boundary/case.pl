# AT-AN-27 (0.1.4 W-18): core's reconcile writes one `compaction_boundary` row (the boundary's sizes and
# the settled idle facts) for a main boundary whose compaction has a rollup row. The real store never
# got one: a boundary row's timestamp comes 0.6 to 3.6 s before its PostCompact (all 57 compactions of
# the 0.1.2/0.1.3 log), so P3 never matched a main boundary to its PostCompact (`by`), the only way to
# the rollup row. The real shape, through the real Stop hook: the mod's dispatch and stream rows, the
# rollup row its after-step wrote 1.2 s after the boundary row's time, the classic PostCompact's rows
# and its stash meta (its copy saved), and the boundary row (followed by Claude Code's idle notice)
# swept after all of them; 5 s before it an older boundary row with no compaction of its own does
# not take the rollup row (the nearest pair wins). The Stop writes the row once, for that nonce, with the boundary's uuid and
# sizes and the idle the notice settles; the watcher's join then reads the compaction as idle. The
# next Stop writes no second row.
my $n = '8c8d0001';
my $id6 = substr($n, 0, 6);
my $B = 100;
my %env = (CLAUDE_CODE_TMPDIR => '$TMP/cctmp', CLAUDE_PROJECT_DIR => '$HOME/work');
my $stop = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                 hook_event_name => 'Stop', stop_hook_active => \0, background_tasks => [], session_crons => [] });
my $rel = "repo/general/compact/2026-10-21_x_c1-$id6.md";
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, $B - 30) },
        { path => '$WATCH/$SID.jsonl',
          jsonl => [ T::row('session_start', 1), T::row('dispatch', $B - 30, nonce => $n, trigger => 'auto', channel => 'mod-hook'),
                     T::row('compacted', $B + 1.1, nonce => $n, skip => undef) ] },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('session', 1, writer => 'classic', phase => 'start', source => 'startup'),
                     T::row('precompact', $B - 30, writer => 'classic', trigger => 'auto', ci_nonce => $n),
                     T::row('postcompact', $B + 1.2, writer => 'classic', nonce_found => $n, scope_found => 'main', verdict => 'ok', trigger => 'auto'),
                     T::row('copy', $B + 1.2, writer => 'classic', result => 'saved', slot => 'main', nonce => $n, id6 => $id6, rel_path => $rel) ] },
        { path => '$WATCH/$SID/compactions.jsonl',
          jsonl => [ T::row('compaction', $B + 1.2, writer => 'mod', actor => 'main', nonce => $n, id6 => $id6, join => 'nonce', trigger => 'auto',
                            verdict => 'ok', channel => 'mod-hook', copy => 'saved', copy_path => $rel, idle => 'unknown', precomputed => \0) ] },
        { path => "\$WATCH/\$SID/pending/$id6.post.json", json => { ts => T::loc($B + 1.2), nonce => $n, scope => 'main', trigger => 'auto' } },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5),
                    # an earlier boundary row 5 s before, with no compaction of its own: the nearest pair wins
                    T::boundary($B - 5, uuid => 'b-standin', trigger => 'auto', preTokens => 198000), T::summary($B - 4.9),
                    T::boundary($B, uuid => 'b-real', trigger => 'auto', preTokens => 612000, postTokens => 41000, durationMs => 52000),
                    { type => 'system', subtype => 'informational', content => 'Compacted while idle for 1h', level => 'info',
                      uuid => T::uid(), sessionId => $T::SID, timestamp => T::z($B + 0.3) },
                    T::summary($B + 0.4), T::prompt($B + 50) ],
    steps => [
        { call => 'code', code => sub { watch::io::mkdir_p("$_[0]{HOME}/work"); watch::io::mkdir_p("$_[0]{TMP}/cctmp") } },
        { call => 'cli', at => $B + 100, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        { call => 'cli', at => $B + 200, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my @cb = $E->rows('$WATCH/$SID/compactions.jsonl', 'compaction_boundary');
        $E->count(\@cb, 1, 'one compaction_boundary row, written once');
        my $r = $cb[0] || {};
        $E->is(join(' ', map { $r->{$_} // 'undef' } qw(nonce boundary_uuid pre_tokens post_tokens duration_ms)), "$n b-real 612000 41000 52000",
               "for the rollup row's nonce, with the boundary's uuid and sizes");
        $E->is(main::Checker::truthy($r->{idle}) ? 'true' : 'false', 'true', 'idle, as the notice after the boundary says');
        $E->is($r->{idle_source}, 'notice', 'idle_source notice');
        # (the watcher joins its PostCompact row to the first boundary within 120 s, here the older one)
        my ($b) = grep { ($_->{nonce} // '') eq $n } $E->boundaries;
        $E->is($b ? (main::Checker::truthy($b->{idle}) ? 'true' : $b->{idle} // 'undef') : 'none', 'true', "the watcher's join reads the compaction as idle");
    },
};

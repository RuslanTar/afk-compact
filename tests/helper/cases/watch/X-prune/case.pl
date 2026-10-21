# `watch prune --days N` (D-9; built and tested, not wired, E-8), run through
# the real launcher. Deletes only UUID-named per-session sets whose every file
# is older than the cut; keeps a set with any newer file, a set holding a
# symlink, and every global file.
my $old = $T::BASE + 3600 - 40 * 86400;
my $new = $T::BASE + 3600 - 86400;
my ($A, $B, $C) = ('aaaaaaaa-1111-4111-8111-111111111111', 'bbbbbbbb-2222-4222-8222-222222222222',
                   'cccccccc-3333-4333-8333-333333333333');
{
    files => [
        { path => "\$WATCH/$A.jsonl", text => "{}\n", mtime => $old },
        { path => "\$WATCH/$A.classic.jsonl", text => "{\"v\":1}\n", mtime => $old },
        { path => "\$WATCH/$A/dispatch/0a0a0a0a.json", text => "{\"x\":1}\n", mtime => $old },
        { path => "\$WATCH/$B.classic.jsonl", text => "{}\n", mtime => $old },
        { path => "\$WATCH/$B.alerts.jsonl", text => "{}\n", mtime => $new },
        { path => "\$WATCH/$C.jsonl", text => "{}\n", mtime => $old },
        { path => "\$WATCH/heal/$A/item.count", text => "1\n", mtime => $old },
        { path => '$WATCH/version.json', text => "{}\n", mtime => $old },
        { path => '$WATCH/evidence-index.tsv', text => "x\n", mtime => $old },
        { path => '$WATCH/notes.txt', text => "x\n", mtime => $old },
    ],
    steps => [
        { call => 'code', code => sub { my $v = shift; mkdir "$v->{WATCH}/$C"; symlink($v->{TMP}, "$v->{WATCH}/$C/link") } },
        { call => 'cli', argv => ['watch', 'prune', '--days', '0'], exit => 64 },
        { call => 'cli', argv => ['watch', 'prune', '--bogus'], exit => 64 },
        { call => 'cli', argv => ['watch', 'report'], exit => 64 },
        { call => 'cli', argv => ['watch', 'prune', '--days', '30'], exit => 0, stdout_re => qr/\Apruned files=3 bytes=19\n\z/ },
        { call => 'cli', argv => ['watch', 'prune', '--days', '30', '--sid', $B], exit => 0, stdout_re => qr/\Apruned files=0 bytes=0\n\z/ },
    ],
    expect => sub {
        my ($E) = @_;
        my $w = $E->var('WATCH');
        $E->ok(!-e "$w/$A.jsonl" && !-e "$w/$A.classic.jsonl" && !-e "$w/$A", 'old session set removed');
        $E->ok(-e "$w/$B.classic.jsonl" && -e "$w/$B.alerts.jsonl", 'a set with a newer file is kept whole');
        $E->ok(-e "$w/$C.jsonl" && -l "$w/$C/link", 'a set holding a symlink is kept');
        $E->ok(-e "$w/heal/$A/item.count" && -e "$w/version.json" && -e "$w/evidence-index.tsv" && -e "$w/notes.txt",
               'global files untouched');
        $E->ok(-d $E->var('TMP'), 'the symlink target is untouched');
        my @r = $E->rows('$WATCH/unknown.classic.jsonl', 'watch_prune');
        $E->count(\@r, 1, 'watch_prune row without --sid');
        $E->is($r[0]{files}, 3, 'row counts');
        $E->count([ $E->rows("\$WATCH/$B.classic.jsonl", 'watch_prune') ], 1, 'row to the given session');
    },
};

# AT-ST-04, watcher status half (C-STORE D4/D10; BUILD-ROUND-9 WCH-06): `status` lists the
# stashes kept after a real copy mismatch (count; this session's share) and the sessions
# whose stash no cross-session finish can reach because they left no per-process record.
# A session with a `live-` or `ended-` record is reachable and not listed; a kept
# `*.mismatch.md` is not an open stash. Counts and sid8s only. Nothing is shown at zero.
my @other = ('0e0e0e0e-1111-4111-8111-111111111111', '0f0f0f0f-2222-4222-8222-222222222222',
             '0a0a0a0a-3333-4333-8333-333333333333');
{
    files => [
        { path => '$WATCH/$SID/pending/aaaaaa.post.mismatch.md', text => "x\n" },
        { path => '$WATCH/$SID/pending/aaaaaa.post.mismatch.json', text => "{}\n" },
        { path => "\$WATCH/$other[0]/pending/bbbbbb.post.md", text => "x\n" },
        { path => "\$WATCH/$other[0]/pending/cccccc.mod.mismatch.md", text => "x\n" },
        { path => "\$WATCH/$other[1]/pending/dddddd.mod.md", text => "x\n" },
        { path => "\$ROOT/.sessions/by-pid/4243-1792570000.ended-0f0f0f0f.json", json => { session_id => $other[1] } },
        { path => "\$WATCH/$other[2]/pending/eeeeee.post.mismatch.md", text => "x\n" },
        { path => '$WATCH/$SID/pending/ffffff.post.md', text => "x\n" },
    ],
    steps => [ { call => 'status', at => 60 } ],
    expect => sub {
        my ($E) = @_;
        my ($l) = $E->outputs;
        my $all = join("\n", @{ $l || [] });
        $E->ok(($all =~ /^Stashes kept after a copy mismatch: 3 \(this session 1\); the plugin never deletes them$/m ? 1 : 0),
               "kept count line ($all)");
        $E->ok(($all =~ /^Stashes no other session can finish \(their session left no process record\): 1 session \(0e0e0e0e\)$/m ? 1 : 0),
               'unreached line names only the session without a record');
    },
};

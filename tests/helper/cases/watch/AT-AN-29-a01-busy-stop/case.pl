# AT-AN-29 (0.1.4 W-8): a Stop whose reconcile cannot take the session's reconcile.lock (a `reconcile`
# call or another session's finish holds it) leaves no waits: reconcile::run says `busy`, and the
# watcher holds the A-01 of each compaction with no copy while a stash of it is still in pending/
# (the lock holder works on it) instead of raising a critical A-01. Through the real `hook` entry on
# the classic path: two compactions whose PostCompact deferred the copy, then a Stop on time while a
# seam holds the lock: no A-01, both held. The lock is released and the second stash is lost: the next
# Stop saves the first copy late (its hold is dropped) and raises the second one's A-01.
my %got;
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my %env = (CLAUDE_CODE_TMPDIR => '$TMP/cctmp', CLAUDE_PROJECT_DIR => '$HOME/work');
my $pl = sub {
    my ($v, %f) = @_;
    return watch::json::encode({ session_id => $T::SID, transcript_path => "$v->{PROJ}/$T::SID.jsonl", cwd => "$v->{HOME}/work", %f });
};
my $base = { session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work' };
my $stop = watch::json::encode({ %$base, hook_event_name => 'Stop', stop_hook_active => \0, background_tasks => [], session_crons => [] });
my $start = watch::json::encode({ %$base, hook_event_name => 'SessionStart', source => 'startup', model => 'm' });
my $compact = sub {
    my ($v, $k) = @_;
    local @ENV{ keys %env } = map { main::sub_vars($_, $v) } values %env;
    my $pre = main::run_child([main::cli_launcher(), 'hook', 'PreCompact'],
                              $pl->($v, hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef), 'cli PreCompact');
    my ($n) = $pre->{stdout} =~ /n=([0-9a-f]{8})/;
    die "PreCompact $k printed no nonce\n" unless defined $n;
    $got{"n$k"} = $n;
    my $sum = "<summary>\n${o}$T::BRAND v1 n=$n s=main${c}\n# LAB-9$k \xe2\x80\x94 retry window fix in review\n## Resume here\n"
            . "Status: working \xc2\xb7 Acuity: stable \xc2\xb7 State: fix in review (checkpoint: clean)\n"
            . "Step 1: `git status` \xe2\x80\x94 for \"finish the review\"\n## User constraints\nnone stated\n## In flight\n"
            . "Nothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n"
            . "## Open questions, user-owned\nnone\n## Next steps\n1. git status \xe2\x80\x94 done when clean \xc2\xb7 todo\n"
            . "${o}/$T::BRAND n=$n${c}\n</summary>";
    my $r = main::run_child([main::cli_launcher(), 'hook', 'PostCompact'],
                            $pl->($v, hook_event_name => 'PostCompact', trigger => 'auto', compact_summary => $sum), 'cli PostCompact');
    die "PostCompact $k: exit $r->{exit}\n" if $r->{exit};
};
my $held = sub {
    my ($v) = @_;
    my $s = watch::io::read_json_file("$v->{WATCH}/$T::SID/offsets/$T::SID.jsonl.off") || {};
    return [ map { $_->{nonce} } @{ ref $s->{session} eq 'HASH' && ref $s->{session}{a01_held} eq 'ARRAY' ? $s->{session}{a01_held} : [] } ];
};
my $snap = sub {
    my ($v, $k) = @_;
    $got{"a01_$k"} = [ grep { ($_->{ev} // '') eq 'alert' && ($_->{rule} // '') eq 'A-01' } @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID.alerts.jsonl") } ];
    $got{"held_$k"} = $held->($v);
    $got{"copies_$k"} = scalar(my @c = glob("$v->{ROOT}/*/*/compact/*.md"));
    $got{"pending_$k"} = [ grep { /\.post\.md\z/ } watch::io::list_dir("$v->{WATCH}/$T::SID/pending") ];
};
my $lock;
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        { call => 'code', code => sub { watch::io::mkdir_p("$_[0]{HOME}/work"); watch::io::mkdir_p("$_[0]{TMP}/cctmp") } },
        { call => 'cli', at => 2, argv => ['hook', 'SessionStart'], stdin => $start, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 3, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        map({ my $k = $_; (
            { call => 'code', at => 10 * $k, code => sub { $compact->($_[0], $k) } },
            { call => 'append', rows => [ T::boundary(10 * $k + 1, uuid => "b-busy-$k", trigger => 'auto', preTokens => 223438, postTokens => 14943),
                                          T::summary(10 * $k + 1.1), ($k == 2 ? (T::prompt(22)) : ()) ] },
        ) } 1 .. 2),
        { call => 'code', code => sub {
              open($lock, '>>', "$_[0]{WATCH}/$T::SID/reconcile.lock") or die "lock: $!";
              flock($lock, 2) or die "flock: $!";
          } },
        { call => 'cli', at => 40, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => { %env, STORE_TEST_WATCH_MIN_MS => '3000' } },
        { call => 'code', code => sub {
              my ($v) = @_;
              close $lock;
              $snap->($v, 'busy');
              for my $f (watch::io::list_dir("$v->{WATCH}/$T::SID/pending")) {
                  next unless $f =~ /\A([0-9a-f]{6}|h[0-9a-f]{5})\.post\.json\z/;
                  my $m = watch::io::read_json_file("$v->{WATCH}/$T::SID/pending/$f") || {};
                  if (($m->{nonce} // '') eq $got{n2}) { unlink "$v->{WATCH}/$T::SID/pending/$1.post.md" or die "unlink: $!"; $got{lost} = 1 }
              }
          } },
        { call => 'cli', at => 50, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        { call => 'code', code => sub { $snap->($_[0], 'next') } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count($got{a01_busy} || [], 0, 'the Stop whose reconcile found the lock held raises no A-01');
        $E->is(join(',', sort @{ $got{held_busy} || [] }), join(',', sort grep { defined } $got{n1}, $got{n2}), 'it holds both A-01 (their stashes are in pending/)');
        $E->is($got{copies_busy}, 0, 'and saves no copy (reconcile did not run)');
        $E->count($got{pending_busy} || [], 2, 'both stashes still in pending/');
        $E->ok($got{lost}, 'the second stash was removed');
        $E->is($got{copies_next}, 1, 'the next Stop saves the first copy late');
        my @a = @{ $got{a01_next} || [] };
        $E->is(join(',', map { $_->{key}{nonce} } @a), $got{n2} // 'x', 'and raises the A-01 of the compaction whose stash is gone, only');
        $E->is(join(',', @{ $got{held_next} || [] }), '', 'nothing is held after it');
    },
};

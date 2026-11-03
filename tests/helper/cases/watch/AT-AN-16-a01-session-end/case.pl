# AT-AN-16 (0.1.3 review round 3, F1): a held A-01 is settled when the session ends, not only at
# a later Stop of its own. Through the real `hook` entry on the classic path: three compactions
# whose PostCompact deferred the copy, and the session's last Stop 1.7 s late
# (STORE_TEST_HOOK_START_AGO_MS), so reconcile leaves the three saves waiting and the watcher
# holds their A-01 (the A-01 row planted for the first one is what the build before the hold
# wrote at that Stop). The third stash then cannot be read. The session ends: its SessionEnd
# (AT-AN-17: another session's cross-session finish, the session having ended with no
# SessionEnd) saves the first two copies in final mode; the watcher's end pass that follows
# closes the planted A-01 as `resolved: copy saved`, drops the second one's hold and raises the
# third one's A-01 (no copy, a stash reconcile no longer waits on). The hold is gone from the
# session state.
# 0.1.4: before that end, two SessionEnds that cannot settle anything: one while another reconciler
# holds the session's reconcile.lock (W-8: reconcile is busy, so its waits say nothing; the stashes
# are still in pending/), one that starts 2 s late (W-9: its reconcile has no time to sweep a save and
# leaves the stashes waiting). Both keep the three A-01 held and write no A-01. AT-AN-17 and AT-AN-21
# finish the session across sessions instead (the next session's start, the `reconcile --orphans`
# CLI, W-7): the rows the end pass writes there carry the ended session's recorded Claude Code
# process (W-13), not the finisher's.
my $finish = $T::AN_FINISH ? 1 : 0;
my $cli = ($T::AN_FINISH // '') eq 'cli' ? 1 : 0;
my %got;
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my %env = (CLAUDE_CODE_TMPDIR => '$TMP/cctmp', CLAUDE_PROJECT_DIR => '$HOME/work', STORE_TEST_CLAUDE_PID => '1111:Tue Oct 21 13:00:00 2026');
my %benv = (%env, STORE_TEST_CLAUDE_PID => '2222:Tue Oct 21 13:30:00 2026');
my $lock;
my $B = 'b0b0b0b0-1111-4222-8333-444444444444';
my $pl = sub {
    my ($v, %f) = @_;
    return watch::json::encode({ session_id => $T::SID, transcript_path => "$v->{PROJ}/$T::SID.jsonl", cwd => "$v->{HOME}/work", %f });
};
my $base = { session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work' };
my $stop = watch::json::encode({ %$base, hook_event_name => 'Stop', stop_hook_active => \0, background_tasks => [], session_crons => [] });
my $start = watch::json::encode({ %$base, hook_event_name => 'SessionStart', source => 'startup', model => 'm' });
my $end = watch::json::encode({ %$base, hook_event_name => 'SessionEnd', reason => 'other' });
my $bstart = watch::json::encode({ session_id => $B, transcript_path => "\$PROJ/$B.jsonl", cwd => '$HOME/work',
                                   hook_event_name => 'SessionStart', source => 'startup', model => 'm' });
my $compact = sub {
    my ($v, $k) = @_;
    local @ENV{ keys %env } = map { main::sub_vars($_, $v) } values %env;
    my $pre = main::run_child([main::cli_launcher(), 'hook', 'PreCompact'],
                              $pl->($v, hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef), 'cli PreCompact');
    my ($n) = $pre->{stdout} =~ /n=([0-9a-f]{8})/;
    die "PreCompact $k printed no nonce\n" unless defined $n;
    $got{"n$k"} = $n;
    my $sum = "<summary>\n${o}$T::BRAND v1 n=$n s=main${c}\n# LAB-5$k \xe2\x80\x94 retry window fix in review\n## Resume here\n"
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
    my $n = 0;
    for my $f (watch::io::list_dir("$v->{WATCH}/$T::SID/offsets")) {
        my $s = watch::io::read_json_file("$v->{WATCH}/$T::SID/offsets/$f") || {};
        $n += scalar @{ $s->{session}{a01_held} || [] } if ref $s->{session} eq 'HASH';
    }
    return $n;
};
my $snap = sub {
    my ($v, $k) = @_;
    my @rows = @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID.alerts.jsonl") };
    $got{"a01_$k"} = [ grep { ($_->{ev} // '') eq 'alert' && ($_->{rule} // '') eq 'A-01' } @rows ];
    $got{"closed_$k"} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @rows ];
    $got{"copies_$k"} = scalar(my @c = glob("$v->{ROOT}/*/*/compact/*.md"));
    $got{"held_$k"} = $held->($v);
    $got{"rows_$k"} = \@rows;
};
my @before_end = $finish ? () : (
    # W-8: another reconciler holds the session's reconcile.lock through the SessionEnd
    { call => 'code', code => sub {
          my ($v) = @_;
          open($lock, '>>', "$v->{WATCH}/$T::SID/reconcile.lock") or die "lock: $!";
          flock($lock, 2) or die "flock: $!";
      } },
    { call => 'cli', at => 45, argv => ['hook', 'SessionEnd'], stdin => $end, stdin_vars => 1, env => \%env },
    { call => 'code', code => sub { close $lock; $snap->($_[0], 'busy') } },
    # W-9: a SessionEnd that starts 2 s late: its reconcile leaves the saves waiting
    { call => 'cli', at => 47, argv => ['hook', 'SessionEnd'], stdin => $end, stdin_vars => 1,
      env => { %env, STORE_TEST_HOOK_START_AGO_MS => '2000' } },
    { call => 'code', code => sub { $snap->($_[0], 'lateend') } },
);
my @ending = $finish ? (
    # the session's process is gone with no SessionEnd: its records say ended, and the next
    # session's start finishes it
    { call => 'code', code => sub {
          my ($v) = @_;
          my $d = "$v->{ROOT}/.sessions/by-pid";
          my $sid8 = substr($T::SID, 0, 8);
          for my $f (watch::io::list_dir($d)) {
              next unless $f =~ /\A(\d+-\d+)\.live-\Q$sid8\E\.json\z/;
              main::write_file("$d/$1.ended-$sid8.json", watch::json::encode({ session_id => $T::SID, reason => 'other', ts => T::loc(59) }) . "\n");
              $got{ended}++;
          }
      } },
    ($cli ? { call => 'cli', at => 60, argv => ['reconcile', '--sid', $B, '--cwd', '$HOME/work', '--orphans'], any_stdout => 1,
              stdout_re => qr/; orphans finished=1 /, env => \%benv }
          : { call => 'cli', at => 60, argv => ['hook', 'SessionStart'], stdin => $bstart, stdin_vars => 1, any_stdout => 1, env => \%benv }),
) : (
    { call => 'cli', at => 60, argv => ['hook', 'SessionEnd'], stdin => $end, stdin_vars => 1, env => \%env },
);
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        { call => 'code', code => sub { watch::io::mkdir_p("$_[0]{HOME}/work"); watch::io::mkdir_p("$_[0]{TMP}/cctmp") } },
        { call => 'cli', at => 2, argv => ['hook', 'SessionStart'], stdin => $start, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 3, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        map({ my $k = $_; (
            { call => 'code', at => 10 * $k, code => sub { $compact->($_[0], $k) } },
            { call => 'append', rows => [ T::boundary(10 * $k + 1, uuid => "b-end-$k", trigger => 'auto', preTokens => 223438, postTokens => 14943),
                                          T::summary(10 * $k + 1.1), ($k == 3 ? (T::prompt(32)) : ()) ] },
        ) } 1 .. 3),
        { call => 'code', code => sub {
              my ($v) = @_;
              my $id = watch::alerts::alert_id('A-01', $T::SID, 'b:b-end-1');
              $got{planted} = $id;
              open(my $fh, '>>:raw', "$v->{WATCH}/$T::SID.alerts.jsonl") or die;
              print $fh watch::json::encode({ %{ T::row('alert', 39, writer => 'classic', plugin_version => '0.1.3') }, alert_id => $id, rule => 'A-01',
                                              severity => 'critical', key => { session_id => $T::SID, actor => 'main', compaction_seq => 1,
                                                                               nonce => $got{n1} }, evidence => { copy => 'missing', line => 5 } }) . "\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1,
          env => { %env, STORE_TEST_HOOK_START_AGO_MS => '1700' } },
        { call => 'code', code => sub { $snap->($_[0], 'late') } },
        @before_end,
        { call => 'code', code => sub {
              my ($v) = @_;
              for my $f (watch::io::list_dir("$v->{WATCH}/$T::SID/pending")) {
                  next unless $f =~ /\A([0-9a-f]{6}|h[0-9a-f]{5})\.post\.json\z/;
                  my $m = watch::io::read_json_file("$v->{WATCH}/$T::SID/pending/$f") || {};
                  next unless ($m->{nonce} // '') eq $got{n3};
                  chmod 0, "$v->{WATCH}/$T::SID/pending/$1.post.md" or die "chmod: $!";
                  $got{unreadable} = 1;
              }
          } },
        @ending,
        { call => 'code', code => sub { $snap->($_[0], 'end') } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{copies_late}, 0, 'no copy at the late last Stop');
        $E->is(join(',', map { $_->{alert_id} } @{ $got{a01_late} || [] }), $got{planted}, 'the late Stop raises no A-01 (only the planted row)');
        $E->is($got{held_late}, 3, 'the late Stop holds the three A-01');
        $E->ok($got{unreadable}, 'the third stash was made unreadable');
        $E->ok($got{ended}, 'the session was marked ended') if $finish;
        $E->is($got{copies_end}, 2, $finish ? 'the cross-session finish saves two copies' : 'SessionEnd saves two copies');
        my @a = @{ $got{a01_end} || [] };
        $E->count(\@a, 2, 'two A-01 rows after the end (the planted one is kept)');
        my %new = map { ($_->{key}{nonce} => $_) } grep { $_->{alert_id} ne ($got{planted} // '') } @a;
        $E->ok(!$new{ $got{n2} // '' }, 'no A-01 for the second compaction (its copy was saved at the end)');
        $E->is($new{ $got{n3} // '' } ? $new{ $got{n3} }{evidence}{copy} : undef, 'missing',
               'the third compaction raises its A-01 at the end (no copy, a stash reconcile no longer waits on)');
        $E->is(join(',', map { "$_->{alert_id}/$_->{rule}/$_->{reason}" } @{ $got{closed_end} || [] }), "$got{planted}/A-01/resolved: copy saved",
               'the planted A-01, whose copy landed at the end, is closed as resolved');
        $E->is($got{held_end}, 0, 'no A-01 is held after the end');
        for my $k ($finish ? () : qw(busy lateend)) {
            my $what = $k eq 'busy' ? 'the SessionEnd whose reconcile found the lock held' : 'the SessionEnd that started late';
            $E->is(join(',', map { $_->{alert_id} } @{ $got{"a01_$k"} || [] }), $got{planted}, "$what raises no A-01 (only the planted row)");
            $E->is($got{"held_$k"}, 3, "$what keeps the three A-01 held");
            $E->is($got{"copies_$k"}, 0, "$what saves no copy");
            $E->count($got{"closed_$k"} || [], 0, "$what closes nothing");
        }
        # W-13: the end pass's rows carry the ended session's own Claude Code process
        my ($third) = grep { ($_->{key}{nonce} // '') eq ($got{n3} // 'x') } @{ $got{a01_end} || [] };
        $E->is($third ? $third->{pid} : undef, 1111, "the A-01 the end pass raised carries the ended session's recorded pid");
        my @cl = grep { ($_->{ev} // '') eq 'alert_closed' } @{ $got{rows_end} || [] };
        $E->is(join(',', map { $_->{pid} // '-' } @cl), '1111', 'so does its alert_closed row');
    },
};

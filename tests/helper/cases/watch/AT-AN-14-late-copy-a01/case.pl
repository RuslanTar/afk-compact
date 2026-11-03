# AT-AN-14 (0.1.3 integration review, hook speed x alerts): a Stop that starts late leaves a
# main-proven save to the next Stop (lib/reconcile.pm SWEEP_MIN_MS). Through the real `hook`
# entry on the classic path: two compactions whose PostCompact deferred the copy for want of a
# scope proof, a Stop 1.7 s late (STORE_TEST_HOOK_START_AGO_MS) that saves neither. Its watcher
# raises no A-01: both stashes still sit in pending/ and reconcile waits on them (the A-01 row
# planted for the first one is what the build before this fix wrote there). Then the second
# stash is lost. The next Stop, on time, saves the first copy late: the planted A-01 is closed
# with `alert_closed {reason: "resolved: copy saved"}` (the row stays) and `status` no longer
# counts it; the second compaction, with no copy and no stash left, raises its A-01 as before.
my %got;
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my %env = (CLAUDE_CODE_TMPDIR => '$TMP/cctmp', CLAUDE_PROJECT_DIR => '$HOME/work');
# a hook payload with the case's paths
my $pl = sub {
    my ($v, %f) = @_;
    return watch::json::encode({ session_id => $T::SID, transcript_path => "$v->{PROJ}/$T::SID.jsonl", cwd => "$v->{HOME}/work", %f });
};
my $base = { session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work' };
my $stop = watch::json::encode({ %$base, hook_event_name => 'Stop', stop_hook_active => \0, background_tasks => [], session_crons => [] });
my $start = watch::json::encode({ %$base, hook_event_name => 'SessionStart', source => 'startup', model => 'm' });
# PreCompact (classic fallback, a fresh nonce), then PostCompact with that nonce's marked summary
my $compact = sub {
    my ($v, $k) = @_;
    local @ENV{ keys %env } = map { main::sub_vars($_, $v) } values %env;
    my $pre = main::run_child([main::cli_launcher(), 'hook', 'PreCompact'],
                              $pl->($v, hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef), 'cli PreCompact');
    my ($n) = $pre->{stdout} =~ /n=([0-9a-f]{8})/;
    die "PreCompact $k printed no nonce\n" unless defined $n;
    $got{"n$k"} = $n;
    my $sum = "<summary>\n${o}$T::BRAND v1 n=$n s=main${c}\n# LAB-4$k \xe2\x80\x94 retry window fix in review\n## Resume here\n"
            . "Status: working \xc2\xb7 Acuity: stable \xc2\xb7 State: fix in review (checkpoint: clean)\n"
            . "Step 1: `git status` \xe2\x80\x94 for \"finish the review\"\n## User constraints\nnone stated\n## In flight\n"
            . "Nothing in flight as of the last message (not checked)\n## Live state\nnone beyond git (not checked)\n"
            . "## Open questions, user-owned\nnone\n## Next steps\n1. git status \xe2\x80\x94 done when clean \xc2\xb7 todo\n"
            . "${o}/$T::BRAND n=$n${c}\n</summary>";
    my $r = main::run_child([main::cli_launcher(), 'hook', 'PostCompact'],
                            $pl->($v, hook_event_name => 'PostCompact', trigger => 'auto', compact_summary => $sum), 'cli PostCompact');
    die "PostCompact $k: exit $r->{exit}\n" if $r->{exit};
};
my $snap = sub {
    my ($v, $k) = @_;
    my @rows = @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID.alerts.jsonl") };
    $got{"a01_$k"} = [ grep { ($_->{ev} // '') eq 'alert' && ($_->{rule} // '') eq 'A-01' } @rows ];
    $got{"closed_$k"} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @rows ];
    $got{"pending_$k"} = [ grep { /\.post\.md\z/ } watch::io::list_dir("$v->{WATCH}/$T::SID/pending") ];
    my @t = grep { ($_->{ev} // '') eq 'stop_timing' } @{ watch::io::read_jsonl("$v->{WATCH}/$T::SID.classic.jsonl") };
    $got{"timing_$k"} = $t[-1];
    $got{"copies_$k"} = scalar(my @c = glob("$v->{ROOT}/*/*/compact/*.md"));
};
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        { call => 'code', code => sub { watch::io::mkdir_p("$_[0]{HOME}/work"); watch::io::mkdir_p("$_[0]{TMP}/cctmp") } },
        { call => 'cli', at => 2, argv => ['hook', 'SessionStart'], stdin => $start, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 3, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        { call => 'code', at => 10, code => sub { $compact->($_[0], 1) } },
        { call => 'append', rows => [ T::boundary(11, uuid => 'b-late-1', trigger => 'auto', preTokens => 223438, postTokens => 14943),
                                      T::summary(11.1) ] },
        { call => 'code', at => 20, code => sub { $compact->($_[0], 2) } },
        { call => 'append', rows => [ T::boundary(21, uuid => 'b-late-2', trigger => 'auto', preTokens => 223438, postTokens => 14943),
                                      T::summary(21.1), T::prompt(22) ] },
        # the A-01 the build before this fix wrote at the late Stop for the first compaction
        { call => 'code', code => sub {
              my ($v) = @_;
              my $id = watch::alerts::alert_id('A-01', $T::SID, 'b:b-late-1');
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
        # the second compaction's stash is lost (its copy will never come)
        { call => 'code', code => sub {
              my ($v) = @_;
              for my $f (watch::io::list_dir("$v->{WATCH}/$T::SID/pending")) {
                  next unless $f =~ /\A([0-9a-f]{6}|h[0-9a-f]{5})\.post\.json\z/;
                  my $m = watch::io::read_json_file("$v->{WATCH}/$T::SID/pending/$f") || {};
                  next unless ($m->{nonce} // '') eq $got{n2};
                  unlink "$v->{WATCH}/$T::SID/pending/$1.post.md" or die "unlink: $!";
                  $got{lost} = 1;
              }
          } },
        { call => 'cli', at => 70, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        { call => 'code', code => sub { $snap->($_[0], 'next') } },
        { call => 'cli', at => 80, argv => ['status', '--sid', '$SID', '--cwd', '$HOME/work'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $t = $got{timing_late} || {};
        $E->ok(scalar(grep { $_ eq 'reconcile' } @{ $t->{cut} || [] }), 'the late Stop cut reconcile (the saves wait)');
        $E->is($got{copies_late}, 0, 'no copy at the late Stop');
        $E->count($got{pending_late} || [], 2, 'both stashes still in pending/ after the late Stop');
        $E->is(join(',', map { $_->{alert_id} } @{ $got{a01_late} || [] }), $got{planted},
               'the late Stop raises no A-01 while reconcile waits on the stashes (only the planted row)');
        $E->count($got{closed_late} || [], 0, 'nothing closed while the copy is still missing');
        $E->ok($got{lost}, 'the second stash was removed');
        $E->is($got{copies_next}, 1, 'the next Stop saves the first copy late');
        my @a = @{ $got{a01_next} || [] };
        $E->count(\@a, 2, 'two A-01 rows after the next Stop (the planted one is kept)');
        my ($new) = grep { $_->{alert_id} ne ($got{planted} // '') } @a;
        $E->is($new ? $new->{key}{nonce} : undef, $got{n2}, 'A-01 for the compaction with no copy and no stash left');
        $E->is($new ? $new->{evidence}{copy} : undef, 'missing', 'its copy is missing');
        my @cl = @{ $got{closed_next} || [] };
        $E->is(join(',', map { "$_->{alert_id}/$_->{rule}/$_->{reason}" } @cl), "$got{planted}/A-01/resolved: copy saved",
               'the A-01 whose copy landed is closed as resolved, once');
        my $st = ($E->outputs)[-1];
        my $out = $st ? $st->{stdout} // '' : '';
        $E->ok(scalar($out =~ /^attention: \d+ open alerts? \(A-01\b/m), 'status still names the open A-01');
        $E->ok(index($out, $got{planted} // 'x') < 0, 'status does not list the closed A-01');
        $E->ok($new && index($out, $new->{alert_id}) >= 0, 'status lists the open A-01');
    },
};

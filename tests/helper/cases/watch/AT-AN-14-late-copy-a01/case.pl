# AT-AN-14 (0.1.3 integration review, hook speed x alerts): a Stop that starts late leaves a
# main-proven save to the next Stop (lib/reconcile.pm SWEEP_MIN_MS), or reaches no stash at all
# when it leaves reconcile no budget. Through the real `hook` entry on the classic path: three
# compactions whose PostCompact deferred the copy for want of a scope proof, a Stop 2.4 s late
# (STORE_TEST_HOOK_START_AGO_MS: reconcile gets 0 ms) and then one 1.7 s late (its saves wait for
# their sweep); neither saves a copy. Their watchers raise no A-01: the stashes still sit in
# pending/ and reconcile waits on them (the A-01 row planted for the first one is what the build
# before this fix wrote there). Then the second stash is lost and the third cannot be read. The
# next Stop, on time, saves the first copy late: the planted A-01 is closed with `alert_closed
# {reason: "resolved: copy saved"}` (the row stays) and `status` no longer counts it; the second
# compaction (no copy, no stash) and the third (a stash reconcile no longer waits on) raise their
# A-01 as before.
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
                                      T::summary(21.1) ] },
        { call => 'code', at => 25, code => sub { $compact->($_[0], 3) } },
        { call => 'append', rows => [ T::boundary(26, uuid => 'b-late-3', trigger => 'auto', preTokens => 223438, postTokens => 14943),
                                      T::summary(26.1), T::prompt(27) ] },
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
          env => { %env, STORE_TEST_HOOK_START_AGO_MS => '2400' } },
        { call => 'code', code => sub { $snap->($_[0], 'late') } },
        { call => 'cli', at => 50, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1,
          env => { %env, STORE_TEST_HOOK_START_AGO_MS => '1700' } },
        { call => 'code', code => sub { $snap->($_[0], 'late2') } },
        # the second compaction's stash is lost (its copy will never come); the third's cannot be read
        { call => 'code', code => sub {
              my ($v) = @_;
              for my $f (watch::io::list_dir("$v->{WATCH}/$T::SID/pending")) {
                  next unless $f =~ /\A([0-9a-f]{6}|h[0-9a-f]{5})\.post\.json\z/;
                  my $m = watch::io::read_json_file("$v->{WATCH}/$T::SID/pending/$f") || {};
                  if (($m->{nonce} // '') eq $got{n2}) { unlink "$v->{WATCH}/$T::SID/pending/$1.post.md" or die "unlink: $!"; $got{lost} = 1 }
                  if (($m->{nonce} // '') eq $got{n3}) { chmod 0, "$v->{WATCH}/$T::SID/pending/$1.post.md" or die "chmod: $!"; $got{unreadable} = 1 }
              }
          } },
        { call => 'cli', at => 70, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
        { call => 'code', code => sub { $snap->($_[0], 'next') } },
        { call => 'cli', at => 80, argv => ['status', '--sid', '$SID', '--cwd', '$HOME/work'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        for my $k (qw(late late2)) {
            my $t = $got{"timing_$k"} || {};
            $E->ok(scalar(grep { $_ eq 'reconcile' } @{ $t->{cut} || [] }), "the $k Stop cut reconcile (the saves wait)");
            $E->is($got{"copies_$k"}, 0, "no copy at the $k Stop");
            $E->count($got{"pending_$k"} || [], 3, "the three stashes still in pending/ after the $k Stop");
            $E->is(join(',', map { $_->{alert_id} } @{ $got{"a01_$k"} || [] }), $got{planted},
                   "the $k Stop raises no A-01 while reconcile waits on the stashes (only the planted row)");
            $E->count($got{"closed_$k"} || [], 0, "nothing closed at the $k Stop while the copy is still missing");
        }
        $E->is(($got{timing_late} || {})->{reconcile_budget_ms}, 0, 'the first late Stop left reconcile no budget');
        $E->ok($got{lost} && $got{unreadable}, 'the second stash was removed, the third made unreadable');
        $E->is($got{copies_next}, 1, 'the next Stop saves the first copy late');
        my @a = @{ $got{a01_next} || [] };
        $E->count(\@a, 3, 'three A-01 rows after the next Stop (the planted one is kept)');
        my %new = map { ($_->{key}{nonce} => $_) } grep { $_->{alert_id} ne ($got{planted} // '') } @a;
        my $new = $new{ $got{n2} // '' };
        $E->ok($new, 'A-01 for the compaction with no copy and no stash left');
        $E->is($new ? $new->{evidence}{copy} : undef, 'missing', 'its copy is missing');
        $E->is($new{ $got{n3} // '' } ? $new{ $got{n3} }{evidence}{copy} : undef, 'missing',
               'A-01 for the compaction whose stash reconcile no longer waits on (it cannot be read)');
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

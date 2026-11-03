# AT-AN-24 (0.1.4 W-15): A-11 (an item listed running for stall_min whose output has not moved for 15
# minutes) now also checks a subagent, by the transcript its tasks/<id>.output link points to, and a
# workflow, by its run journal (<project>/<sid>/subagents/workflows/<run>/journal.jsonl; the run is the
# one its launch result named in the transcript). A quiet subagent and a quiet workflow raise A-11
# (source derived); a subagent and a workflow whose files grew stay silent; a teammate stays
# unchecked. The resolved path is kept in the session state (`task_out`) when the item is first
# seen.
my ($aq, $ag, $wq, $wg) = ('a0123456789abcdef', 'afedcba9876543210', 'wquiet001', 'wgrows002');
my ($rq, $rg) = ('wf_11111111-aaa', 'wf_22222222-bbb');
my $launch = sub {
    my ($t, $task, $run) = @_;
    my $r = T::result($t, "toolu_$task");
    $r->{toolUseResult} = { status => 'async_launched', taskId => $task, taskType => 'local_workflow', runId => $run };
    return $r;
};
my $at = 4000;
my @tasks = (map({ { id => $_, type => 'subagent', status => 'running', output_path => undef } } $aq, $ag),
             map({ { id => $_, type => 'workflow', status => 'running', output_path => undef } } $wq, $wg),
             { id => 'tteam0001', type => 'teammate', status => 'running', output_path => undef });
my %got;
{
    files => [
        { path => '$WATCH/$SID/bg/slot-0.json', json => { v => 1, ts => T::loc(0), set_hash => 'h0', tasks => \@tasks } },
        { path => "\$PROJ/\$SID/subagents/agent-$aq.jsonl", text => "{}\n", mtime => $T::BASE + $at - 1200 },
        { path => "\$PROJ/\$SID/subagents/agent-$ag.jsonl", text => "{}\n", mtime => $T::BASE + $at - 60 },
        { path => "\$PROJ/\$SID/subagents/workflows/$rq/journal.jsonl", text => "{}\n", mtime => $T::BASE + $at - 1200 },
        { path => "\$PROJ/\$SID/subagents/workflows/$rg/journal.jsonl", text => "{}\n", mtime => $T::BASE + $at - 60 },
        # a workflow's own output file stays empty until it ends (it does not show progress)
        { path => "\$TMP/cctmp/claude-$</-synthetic-proj/\$SID/tasks/$wq.output", text => '', mtime => $T::BASE + 10 },
        { path => "\$TMP/cctmp/claude-$</-synthetic-proj/\$SID/tasks/$wg.output", text => '', mtime => $T::BASE + 10 },
    ],
    transcript => [ T::prompt(0), $launch->(1, $wq, $rq), $launch->(2, $wg, $rg), T::assistant_text(5) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $d = "$v->{TMP}/cctmp/claude-$</-synthetic-proj/$T::SID/tasks";
              watch::io::mkdir_p($d);
              for my $id ($aq, $ag) { symlink("$v->{PROJ}/$T::SID/subagents/agent-$id.jsonl", "$d/$id.output") or die "symlink: $!" }
          } },
        { call => 'stop', at => $at },
        { call => 'code', code => sub {
              my $st = watch::io::read_json_file("$_[0]{WATCH}/$T::SID/offsets/$T::SID.jsonl.off") || {};
              $got{kept} = ref $st->{session}{task_out} eq 'HASH' ? $st->{session}{task_out} : {};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-11');
        my %by = map { ($_->{alert_id} => $_) } @a;
        my $id = sub { watch::alerts::alert_id('A-11', $T::SID, $_[0]) };
        $E->is(join(',', sort map { my $x = $_; (grep { $id->($_) eq $x->{alert_id} } $aq, $ag, $wq, $wg, 'tteam0001')[0] // '?' } @a),
               join(',', sort $aq, $wq), 'A-11 for the quiet subagent and the quiet workflow only');
        $E->is(join(',', map { ($by{ $id->($_) } || {})->{evidence}{source} // '-' } $aq, $wq), 'derived,derived', 'their source is derived');
        my $k = $got{kept} || {};
        $E->ok((($k->{$aq} // '') =~ m{/subagents/agent-\Q$aq\E\.jsonl\z} ? 1 : 0), "the subagent's transcript is kept as its output path");
        $E->ok((($k->{$wq} // '') =~ m{/subagents/workflows/\Q$rq\E/journal\.jsonl\z} ? 1 : 0), "the workflow's run journal is kept");
        $E->ok(!exists $k->{tteam0001}, 'nothing for the teammate');
    },
};

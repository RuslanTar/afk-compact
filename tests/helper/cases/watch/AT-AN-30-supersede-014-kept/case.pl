# AT-AN-30 (0.1.4 W-6, W-15; lib/watch/supersede.pm): what the 0.1.4 re-check of older rows keeps
# open. Another session (OTHER) holds older rows. A-09 (changed in 0.1.4) is re-run on the saved
# copies: the row whose copy, compared with the previous own copy, loses nothing (U-3 renumbered
# U-7) is closed; a row of the same compaction that compared against the transcript
# (ledger_src transcript) stays open, as does a row whose own copy cannot be read (its file is
# gone). A-11 of a background workflow (0.1.2 flagged every item with no output path): the
# workflow's run journal had not changed for 20 minutes before the alert, but an agent transcript
# in its run folder changed a minute before it (the journal gets a row only when an agent starts or
# ends), so whether the workflow was quiet then cannot be told: closed. One whose journal and
# agent transcripts had all been unchanged for the 16 minutes before the alert stays open.
# W-15 (review F-3): the A-11 output path the sweep kept in session state (`task_out`) is read
# first: a background shell whose output file is in no task folder, kept there and quiet for the
# 16 minutes before the alert, stays open (re-derived from the task folders it would be unchecked,
# so closed).
# W-6/W-2 (review F-4): an A-27 of 0.1.3 whose continue follows an observed boundary but is the
# plugin's handoff-turn submit (told by its text; its ht record gone) is no continue: closed. A plain
# continue after the same boundary stays open.
my $OTHER = '4d4e5f60-0000-4000-8000-00000000c0de';
my ($c1, $c2, $c4) = ('3e3f0101', '3e3f0102', '3e3f0104');
my ($wb, $rb, $wq, $rq) = ('wbusy0004', 'wf_44444444-ddd', 'wquiet005', 'wf_55555555-eee');
my $bk = 'bkept0006';
my ($submit) = do {
    open(my $fh, '<:raw', "$T::REPO/plugin/assets/handoff-turn.txt") or die "handoff-turn.txt: $!";
    map { /\A\[submit-(?:halt|pre|idle)\] (Note from .*)\z/ ? do { (my $x = $1) =~ s/\@[a-z_]+\@/7/g; $x } : () } map { s/\r?\n\z//r } <$fh>;
};
my $sub_row = T::continue_row(1700, sid => $OTHER);
$sub_row->{message}{content} = "The $T::BRAND plugin sent a message:\n$submit";
my @otr = ((map { T::assistant_text(1000 + $_, sid => $OTHER) } 1 .. 11), $sub_row, T::assistant_text(1701, sid => $OTHER),
           T::continue_row(1800, sid => $OTHER), T::assistant_text(1801, sid => $OTHER));
my %brec = (attributed => 'main', copy => 'missing', idle => undef, seq => 1, nonce => 'none', join => undef, channel => undef,
            postcompact => \0, precomputed => \0, trigger => 'auto', uuid => 'u-obs', ts => T::loc(1500), line => 10);
my $aid = sub { watch::alerts::alert_id($_[0], $OTHER, @_[1 .. $#_]) };
my $alert = sub {
    my ($rule, $sev, $id, %o) = @_;
    my $r = T::row('alert', 2000, writer => 'classic', sid => $OTHER, alert_id => $id, rule => $rule, severity => $sev,
                   key => { session_id => $OTHER, actor => 'main', nonce => ($o{nonce} // 'none') }, evidence => $o{evidence} || {});
    $r->{plugin_version} = $o{version};
    return $r;
};
my $lost = { lost_U => 1, lost_D => 0, lost_X => 0 };
my @old = (
    $alert->('A-09', 'critical', $aid->('A-09', "p:$c2"), nonce => $c2, version => '0.1.3', evidence => { %$lost, ledger_src => 'copy' }),
    $alert->('A-09', 'critical', $aid->('A-09', "t:$c2"), nonce => $c2, version => '0.1.3', evidence => { %$lost, ledger_src => 'transcript' }),
    $alert->('A-09', 'critical', $aid->('A-09', "p:$c4"), nonce => $c4, version => '0.1.3', evidence => { %$lost, ledger_src => 'copy' }),
    map({ $alert->('A-11', 'warn', $aid->('A-11', $_), version => '0.1.2', evidence => { output_known => \0, minutes => 90 }) } $wb, $wq, $bk),
    $alert->('A-27', 'warn', $aid->('A-27', 'cont-sub'), version => '0.1.3', evidence => { continue_without_nudge => \1, line => 12 }),
    $alert->('A-27', 'warn', $aid->('A-27', 'cont-plain'), version => '0.1.3', evidence => { continue_without_nudge => \1, line => 14 }),
);
my $body = sub { my ($n, @u) = @_; return "---\nkind: compact-summary\n---\n" . T::main_body(nonce => $n, U => \@u) };
my $rel = sub { "repo/general/compact/2026-10-21_x_c$_[0]-" . substr($_[1], 0, 6) . '.md' };
my $copy = sub { my ($k, $n, $t) = @_; return { %{ T::row('copy', $t, writer => 'classic', result => 'saved', slot => 'main', nonce => $n,
                                                           id6 => substr($n, 0, 6), rel_path => $rel->($k, $n)) }, sid => $OTHER } };
my $pc = sub { my ($n, $t) = @_; return { %{ T::row('postcompact', $t, writer => 'classic', nonce_found => $n, scope_found => 'main', verdict => 'ok') },
                                          sid => $OTHER } };
my $run = "\$HOME/.claude/projects/-other-proj/$OTHER/subagents/workflows";
my @tasks = ({ id => $wb, type => 'workflow', status => 'running', output_path => undef, run_id => $rb },
             { id => $wq, type => 'workflow', status => 'running', output_path => undef, run_id => $rq },
             { id => $bk, type => 'shell', status => 'running', output_path => undef });
my %got;
{
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    files => [
        { path => "\$WATCH/$OTHER.classic.jsonl",
          jsonl => [ { %{ T::row('config_note', 1000, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') }, sid => $OTHER },
                     $copy->(1, $c1, 1100), $pc->($c2, 1199), $copy->(2, $c2, 1200), $pc->($c4, 1399), $copy->(4, $c4, 1400),
                     { %{ T::row('sweep', 1900, writer => 'classic') }, sid => $OTHER, file => "$OTHER.jsonl", boundaries => [ \%brec ] } ] },
        { path => "\$HOME/.claude/projects/-other-proj/$OTHER.jsonl", jsonl => \@otr },
        { path => '$ROOT/' . $rel->(1, $c1), text => $body->($c1, 'U-3: keep the queue (checked 2026-10-21 14:05 +0300)', 'U-2 "CANARY-TEXT-two"') },
        { path => '$ROOT/' . $rel->(2, $c2), text => $body->($c2, 'U-7 Keep the queue', 'U-2 "CANARY-TEXT-two"') },
        # no file for the fourth compaction's copy: it cannot be read
        { path => "\$WATCH/$OTHER.alerts.jsonl", jsonl => \@old },
        { path => "\$WATCH/$OTHER/bg/slot-0.json", json => { v => 1, ts => T::loc(100), set_hash => 'h0', tasks => \@tasks } },
        { path => "$run/$rb/journal.jsonl", text => "{}\n", mtime => $T::BASE + 2000 - 1200 },
        { path => "$run/$rb/agent-a3333333333333333.jsonl", text => "{}\n", mtime => $T::BASE + 2000 - 60 },
        { path => "$run/$rq/journal.jsonl", text => "{}\n", mtime => $T::BASE + 2000 - 960 },
        { path => "$run/$rq/agent-a4444444444444444.jsonl", text => "{}\n", mtime => $T::BASE + 2000 - 1000 },
        { path => "\$WATCH/kept-out/$bk.output", text => "done\n", mtime => $T::BASE + 2000 - 1000 },
    ],
    steps => [
        { call => 'code', code => sub {
              main::write_file("$_[0]{WATCH}/$OTHER/offsets/$OTHER.jsonl.off",
                               watch::json::encode({ session => { task_out => { $bk => "$_[0]{WATCH}/kept-out/$bk.output" } } }) . "\n");
          } },
        { call => 'stop', at => 3000, ctx => { plugin_version => '0.1.4' } },
        { call => 'code', code => sub {
              $got{closed} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$_[0]{WATCH}/$OTHER.alerts.jsonl") } ];
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @c = @{ $got{closed} || [] };
        $E->is(join(',', sort map { $_->{alert_id} } @c), join(',', sort($aid->('A-09', "p:$c2"), $aid->('A-11', $wb), $aid->('A-27', 'cont-sub'))),
               'closed: the A-09 whose copies lose nothing under the 0.1.4 rule, the A-11 of the workflow whose agent was working, the A-27 of a handoff-turn submit');
        my %c = map { ($_->{alert_id} => $_) } @c;
        $E->ok(!$c{ $aid->('A-09', "t:$c2") }, 'an A-09 that compared against the transcript stays open');
        $E->ok(!$c{ $aid->('A-09', "p:$c4") }, 'an A-09 whose own copy cannot be read stays open');
        $E->ok(!$c{ $aid->('A-11', $wq) }, 'the A-11 of the workflow whose journal and agents were all quiet stays open');
        $E->ok(!$c{ $aid->('A-11', $bk) }, 'the A-11 of the shell whose kept output path (task_out) was quiet stays open');
        $E->ok(!$c{ $aid->('A-27', 'cont-plain') }, 'the A-27 of a plain continue after the observed boundary stays open');
        $E->is(join(',', sort map { "$_->{rule}:$_->{reason}" } @c),
               'A-09:superseded: rule changed in 0.1.4,A-11:superseded: rule changed in 0.1.3,A-27:superseded: rule changed in 0.1.4', 'each with the version its rule changed in');
    },
};

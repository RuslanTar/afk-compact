# AT-AN-23 (0.1.4 W-14): one definition of a session's first record (core's sessions::first_row) for
# core's order canary (reconcile::cutoff) and the watcher's history skip (watch::rules::observed_from):
# the first row that is not one a Stop writes itself. The classic stream starts with a Stop's sweep
# row (at 10 s) and then the SessionStart row (at 20 s); both give 20 s. Through the real Stop hook: a
# boundary at 15 s (before the first record) and one at 30 s, neither with a PostCompact: the order
# canary flags only the one at 30 s (before: both, from the sweep row's time), and the watcher's
# hookless A-15 is raised for the same one (the one at 15 s is history).
my %env = (CLAUDE_CODE_TMPDIR => '$TMP/cctmp', CLAUDE_PROJECT_DIR => '$HOME/work');
my $stop = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                 hook_event_name => 'Stop', stop_hook_active => \0, background_tasks => [], session_crons => [] });
my %got;
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('sweep', 10, writer => 'classic', file => "$T::SID.jsonl", from_off => 0, to_off => 10, boundaries => []),
                     T::row('session', 20, writer => 'classic', phase => 'start', source => 'startup') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), T::boundary(15, uuid => 'b-before', trigger => 'auto'), T::summary(15.1),
                    T::prompt(25), T::boundary(30, uuid => 'b-after', trigger => 'auto'), T::summary(30.1), T::prompt(40) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{HOME}/work");
              watch::io::mkdir_p("$v->{TMP}/cctmp");
              require sessions;
              $got{first} = sessions::first_row("$v->{WATCH}/$T::SID", "$v->{WATCH}/$T::SID.classic.jsonl", "$v->{WATCH}/$T::SID.jsonl");
              require watch::rules;
              $got{obs} = watch::rules::observed_from({ watch => $v->{WATCH}, sid => $T::SID });
          } },
        { call => 'cli', at => 100, argv => ['hook', 'Stop'], stdin => $stop, stdin_vars => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{first}, $T::BASE + 20, "sessions::first_row: the SessionStart row's time, not the sweep row's");
        $E->is($got{obs}, $got{first}, 'observed_from gives the same time');
        my @oa = grep { ($_->{kind} // '') eq 'boundary-without-postcompact' } $E->rows('classic', 'order_anomaly');
        $E->is(join(',', map { $_->{uuid} // '-' } @oa), 'b-after', 'the order canary flags only the boundary after the first record');
        my @h = grep { ref $_->{evidence} eq 'HASH' && $_->{evidence}{hookless_boundary} } $E->alerts('A-15');
        $E->count(\@h, 1, 'one hookless A-15: the watcher skips the same history boundary');
        $E->is(@h ? $h[0]{evidence}{line} : undef, 6, 'for the boundary after the first record (transcript line 6)');
    },
};

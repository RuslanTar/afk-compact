# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1 review finding 1): the watcher checks its roots in
# core's path form (util::clean_path, as paths::for), so roots.pm's per-string cache answers
# from core's own check and the watcher runs no git check-ignore of its own. The home folder
# is a dotfiles repository that ignores .claude/ (the roots are ok). The real launcher's
# PreCompact runs three times, each a session of its own: HOME as is (the baseline), HOME with
# a trailing slash, and handoff_root written `$HOME/.claude/./handoffs`. Each writes the
# watcher's precompact row, and each asks git exactly as often as the baseline. Before the
# fix the watcher checked the raw strings: a trailing-slash HOME took 14 git calls against 9,
# and with PreCompact's 500 ms mostly spent by core the check ran out of time
# (root-unchecked) and the watcher's row was lost in 3 runs of 5.
my %sid = (base => '1b2c3d4e-0000-4000-8000-00000000f001', slash => '1b2c3d4e-0000-4000-8000-00000000f002',
           dot => '1b2c3d4e-0000-4000-8000-00000000f003');
my $pre = sub {
    my ($s) = @_;
    return watch::json::encode({ session_id => $s, transcript_path => "\$PROJ/$s.jsonl", cwd => '$HOME/work',
                                 hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
};
my $git_calls = sub {
    my ($f) = @_;
    my $t = watch::io::slurp($f);
    return undef unless defined $t;
    my $n = () = $t =~ /^git$/mg;
    return $n;
};
{
    needs => ['cmd:git'],
    needs_note => 'the ignored-root test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n";
              close $fh;
              my $t = watch::io::slurp($v->{TRANSCRIPT});
              for my $s (values %sid) {
                  open(my $o, '>', "$v->{PROJ}/$s.jsonl") or die "transcript: $!";
                  print $o $t;
                  close $o;
              }
          } },
        { call => 'cli', at => 9, argv => ['hook', 'PreCompact'], stdin => $pre->($sid{base}), stdin_vars => 1,
          any_stdout => 1, env => { STORE_TEST_TRACE => '$TMP/trace-base.log' } },
        { call => 'cli', at => 10, argv => ['hook', 'PreCompact'], stdin => $pre->($sid{slash}), stdin_vars => 1,
          any_stdout => 1, env => { HOME => '$HOME/', STORE_TEST_TRACE => '$TMP/trace-slash.log' } },
        { call => 'cli', at => 11, argv => ['hook', 'PreCompact'], stdin => $pre->($sid{dot}), stdin_vars => 1,
          any_stdout => 1, env => { CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT => '$HOME/.claude/./handoffs',
                                    STORE_TEST_TRACE => '$TMP/trace-dot.log' } },
    ],
    expect => sub {
        my ($E) = @_;
        my $tmp = $E->var('TMP');
        my $base = $git_calls->("$tmp/trace-base.log");
        $E->ok(defined $base && $base > 0, 'the baseline run asked git (the trace has git lines)');
        for my $k (qw(base slash dot)) {
            $E->count([ $E->rows("\$WATCH/$sid{$k}.classic.jsonl", 'precompact') ], 1, "$k: the watcher's precompact row");
            $E->count([ $E->rows("\$WATCH/$sid{$k}.classic.jsonl", 'watch_error') ], 0, "$k: no watch_error row");
            next if $k eq 'base';
            $E->is($git_calls->("$tmp/trace-$k.log"), $base, "$k: git calls as many as the baseline");
        }
    },
};

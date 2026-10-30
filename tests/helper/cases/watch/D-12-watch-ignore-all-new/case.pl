# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): the control for the not-made-yet checks. A dotfiles
# home that ignores everything (`*`) and a log_dir ($HOME/wlogs) not made yet: the root is
# ignored, so it is ok from the first call on. Both launcher calls write their precompact row
# there, `status` has no refusal and `git status` shows nothing under wlogs.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the ignored-root test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh "*\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 42, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        $E->count([ $E->rows("$home/wlogs/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 2,
                  'both launcher calls wrote their precompact row');
        my $st = `git -C '$home' status --porcelain --untracked-files=all 2>&1`;
        my @w = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @w), '', 'git status shows nothing under wlogs');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt !~ /writes nothing/), "no refusal line in status: $txt");
    },
};

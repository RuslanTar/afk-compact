# Unsafe roots: log_dir is $HOME/wlogs inside a dotfiles home that
# ignores `.claude/`, `.local/state/<plugin>/` and `wlogs/`. A folder-only pattern (`wlogs/`) matches only a folder, so
# git check-ignore must be asked about `wlogs/` (trailing slash) while the folder is not made
# yet. Both roots are git-ignored, so the watcher writes its rows to $HOME/wlogs and `status`
# has no refusal. Before the fix roots::check_path asked about `wlogs`, got root-in-git, and
# the watcher wrote nothing on every call.
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
              print $fh ".claude/\n.local/state/$T::BRAND/\nwlogs/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 42, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        $E->ok(scalar(-d "$home/wlogs"), 'the configured log_dir was made');
        $E->count([ $E->rows("$home/wlogs/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 2,
                  'watcher precompact rows in log_dir');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt !~ /refused|writes nothing/), "status has no refusal: $txt");
    },
};

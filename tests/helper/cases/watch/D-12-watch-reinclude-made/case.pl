# Unsafe roots: log_dir is $HOME/wlogs, already made, in a dotfiles
# home whose .gitignore ignores .claude/, .local/state/<plugin>/ and the contents of wlogs (`wlogs/*`) but brings
# `*.jsonl` back there. git says the folder wlogs itself is not ignored, so log_dir is
# root-in-git: nothing is written there and `git status` shows nothing new under wlogs. Asked
# with a trailing slash, git matched `wlogs/*` against an empty name inside wlogs and called
# the root ignored, and the launcher's PreCompact wrote its classic log into the repository.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root-in-git test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\nwlogs/*\n!wlogs/*.jsonl\n";
              close $fh;
              mkdir "$v->{HOME}/wlogs" or die "mkdir: $!";
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        my $st = `git -C '$home' status --porcelain --untracked-files=all 2>&1`;
        my @w = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @w), '', 'git status shows nothing new under wlogs');
        $E->count([ $E->rows("$home/wlogs/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 0, 'no watcher row in wlogs');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

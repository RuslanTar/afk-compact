# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): log_dir $HOME/wlogs, not made yet, in a dotfiles home
# whose .gitignore says `wlogs` and then `!wlogs/`: the name is ignored, but a folder of that
# name is brought back, and files in it are not ignored. Asked as written (git cannot know it
# will be a folder) the root reads ignored; it is root-in-git all the same, so no call makes it
# and `git status` shows nothing under wlogs.
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
              print $fh ".claude/\n.local/state/$T::BRAND/\nwlogs\n!wlogs/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        my $st = `git -C '$home' status --porcelain --untracked-files=all 2>&1`;
        my @w = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @w), '', 'git status shows nothing under wlogs');
        $E->ok(!-e "$home/wlogs", 'wlogs is not made');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

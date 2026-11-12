# Unsafe roots: HOME is a dotfiles work tree whose .gitignore says
# `x/`, and log_dir is $HOME/:(top)x/wlogs, not made yet. Nothing ignores the folder `:(top)x`,
# so git status would show the watcher's files: root-in-git. The root is sent on stdin relative
# to the work tree with `./` in front; sent bare, git reads `:(top)x/wlogs` as pathspec magic
# for x/wlogs, which `x/` ignores, and the root would pass as ignored.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/:(top)x/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh "x/\n.claude/\n.local/state/$T::BRAND/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $d = $E->var('HOME');
        my $st = `git -C '$d' status --porcelain --untracked-files=all 2>&1`;
        my @x = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @x), '', 'git status shows nothing under wlogs');
        $E->ok(!-e "$d/:(top)x/wlogs", 'log_dir not made');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

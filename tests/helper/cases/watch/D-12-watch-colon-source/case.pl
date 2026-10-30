# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): the folder holding the deciding .gitignore is named
# `x:1:y`, and its .gitignore says `*`, then `!*`. log_dir $HOME/x:1:y/wlogs is not made yet;
# git's last match for it is `!*` (not ignored), so it is root-in-git. Git names that match
# `x:1:y/.gitignore:2:!*`: a parse of that text that splits at the first `:<digits>:` reads
# the pattern as `y/.gitignore:2:!*`, takes it for an ignore, and the watcher writes into the
# repository. The root check reads git's NUL-separated fields (-z), so no colon can move them.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/x:1:y/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\n";
              close $fh;
              watch::io::mkdir_p("$v->{HOME}/x:1:y");
              open($fh, '>', "$v->{HOME}/x:1:y/.gitignore") or die "gitignore: $!";
              print $fh "*\n!*\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        $E->ok(!-e "$home/x:1:y/wlogs", 'log_dir not made');
        my $st = `git -C '$home' status --porcelain --untracked-files=all 2>&1`;
        my @w = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @w), '', 'git status shows nothing under wlogs');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

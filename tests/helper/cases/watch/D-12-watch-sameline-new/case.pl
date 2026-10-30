# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): log_dir $HOME/wlogs, not made yet, in a home whose
# .gitignore says `wlogs`, then `!wlogs/` (a folder of that name is brought back), then
# `wlogs/*` and `!wlogs/*.jsonl`. As written the root reads ignored (by `wlogs`), with a slash
# it reads ignored (by `wlogs/*`, matching the empty entry): two different lines, so it is
# root-in-git. Accepting on "both forms ignored" alone (no same-line check) makes the folder
# and its .jsonl files show in git status.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\nwlogs\n!wlogs/\nwlogs/*\n!wlogs/*.jsonl\n";
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
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

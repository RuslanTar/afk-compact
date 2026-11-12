# Unsafe roots: HOME is a work tree whose .gitignore says `*`, then
# `!Café/` and `!Café/**` (NFC). log_dir $HOME/Café (NFC) is not made yet. The folder is
# brought back with its files, so git status would show the watcher's files: root-in-git. The
# name is NFC-stable, so it is asked on stdin in both forms like an ASCII one (on the command
# line `*` matches the path as written and `!Café/` is skipped: it read as ignored).
my $w = "Caf\xc3\xa9";
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/' . $w);
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh "*\n!$w/\n!$w/**\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $d = $E->var('HOME');
        my $st = `git -C '$d' status --porcelain --untracked-files=all 2>&1`;
        my @x = grep { m{Caf} } split /\n/, $st;
        $E->is(join(' | ', @x), '', 'git status shows nothing under Café');
        $E->ok(!-e "$d/$w", 'log_dir not made');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

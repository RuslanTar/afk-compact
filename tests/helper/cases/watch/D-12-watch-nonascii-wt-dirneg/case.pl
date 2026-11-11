# Unsafe roots: a work tree $HOME/Café (NFC name, nothing decomposed)
# whose .gitignore says `*`, then `!wlogs/` and `!wlogs/**`. log_dir $HOME/Café/wlogs is not
# made yet. The folder is brought back and its files are not ignored, so git status would show
# the watcher's files: root-in-git. The same case under an ASCII work tree is refused; a
# non-ASCII byte in the work tree's own path must not change the answer (asked on the command
# line, `*` matches the path as written and `!wlogs/` is skipped: it read as ignored).
my $w = "Caf\xc3\xa9";
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/' . $w . '/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $d = "$v->{HOME}/$w";
              watch::io::mkdir_p($d);
              system('git', 'init', '-q', $d) == 0 or die "git init failed\n";
              open(my $fh, '>', "$d/.gitignore") or die "gitignore: $!";
              print $fh "*\n!wlogs/\n!wlogs/**\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $d = $E->var('HOME') . "/$w";
        my $st = `git -C '$d' status --porcelain --untracked-files=all 2>&1`;
        my @x = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @x), '', 'git status shows nothing under wlogs');
        $E->ok(!-e "$d/wlogs", 'log_dir not made');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

# Unsafe roots: log_dir $HOME/Café/wlogs is not made yet; the folder
# Café exists with its name stored decomposed (NFD: e + U+0301, as macOS apps often make it).
# The home's .gitignore says `*`, then `!Café/` and `!Café/**` written composed (NFC). git
# (core.precomposeUnicode, set by git init on macOS) reads folder names and command-line paths
# as NFC, so git status shows the watcher's files under Café/wlogs and
# `git check-ignore -q --no-index <log_dir>` says not ignored: root-in-git. Paths read from
# --stdin are not precomposed, so a stdin check sees `Cafe+U+0301`, misses `!Café/`, and
# `*` makes the root look ignored.
# Where git does not precompose (Linux: git init sets no core.precomposeUnicode, and the file
# system keeps the NFD bytes), git reads the folder as `Cafe+U+0301` everywhere: `!Café/`
# never matches it, `*` ignores Café/wlogs, git status shows nothing there, and the watcher
# rightly writes its rows with no refusal. The case asserts the outcome of the git it runs.
my $nfd = "Cafe\xcc\x81";
my $nfc = "Caf\xc3\xa9";
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/' . $nfd . '/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>:raw', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh "*\n!$nfc/\n!$nfc/**\n";
              close $fh;
              mkdir "$v->{HOME}/$nfd" or die "mkdir: $!";
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        my $pre_nfc = `git -C '$home' config --bool core.precomposeunicode 2>/dev/null`;
        chomp $pre_nfc;
        my $st = `git -C '$home' status --porcelain --untracked-files=all 2>&1`;
        my @w = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @w), '', 'git status shows nothing under wlogs');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        if ($pre_nfc eq 'true') {
            $E->ok(!-e "$home/$nfd/wlogs", 'log_dir not made');
            $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
        } else {
            $E->count([ $E->rows("$home/$nfd/wlogs/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 1,
                      'git does not precompose: watcher precompact row in log_dir');
            $E->ok(scalar($txt !~ /refused|writes nothing/), "git does not precompose: status has no refusal: $txt");
        }
    },
};

# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): log_dir $HOME/Café/wlogs is not made yet; the folder
# Café exists with its name stored decomposed (NFD: e + U+0301, as macOS apps often make it).
# The home's .gitignore says `*`, then `!Café/` and `!Café/**` written composed (NFC). git
# (core.precomposeUnicode, set by git init on macOS) reads folder names and command-line paths
# as NFC, so git status shows the watcher's files under Café/wlogs and
# `git check-ignore -q --no-index <log_dir>` says not ignored: root-in-git. Paths read from
# --stdin are not precomposed, so a stdin check sees `Cafe+U+0301`, misses `!Café/`, and
# `*` makes the root look ignored.
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
        $E->ok(!-e "$home/$nfd/wlogs", 'log_dir not made');
        my $st = `git -C '$home' status --porcelain --untracked-files=all 2>&1`;
        my @w = grep { m{wlogs/} } split /\n/, $st;
        $E->is(join(' | ', @w), '', 'git status shows nothing under wlogs');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says log_dir is refused: $txt");
    },
};

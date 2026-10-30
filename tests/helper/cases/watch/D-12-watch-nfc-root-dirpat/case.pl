# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): HOME is a work tree whose .gitignore says `Café/`
# (NFC) and `.claude/`. log_dir $HOME/Café is not made yet and git ignores it once made, so
# the watcher writes its rows there and status has no refusal. The name is NFC-stable, so it
# is asked on stdin with a trailing slash like an ASCII one (on the command line the folder-
# only pattern misses the path as written and the root was refused until made).
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
              print $fh "$w/\n.claude/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $d = $E->var('HOME') . "/$w";
        $E->count([ $E->rows("$d/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 1,
                  'watcher precompact row in log_dir');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(!scalar($txt =~ /^Watcher: writes nothing|refused/m), "status has no refusal: $txt");
    },
};

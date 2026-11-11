# Unsafe roots: a work tree $HOME/Café (NFC name) whose .gitignore
# says `wlogs/`. log_dir $HOME/Café/wlogs is not made yet and git ignores it once made, so the
# watcher writes its rows there and status has no refusal (an ASCII work tree like this is
# D-12-watch-logdir-dirpattern). A non-ASCII byte in the work tree's own path must not make
# the folder-only pattern miss, or the root is refused on every call (the watcher never makes it).
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
              print $fh "wlogs/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $d = $E->var('HOME') . "/$w";
        $E->count([ $E->rows("$d/wlogs/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 1,
                  'watcher precompact row in log_dir');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt !~ /refused|writes nothing/), "status has no refusal: $txt");
    },
};

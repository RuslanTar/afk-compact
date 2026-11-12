# Unsafe roots: a work tree $HOME/Café/proj whose folder Café is stored
# decomposed (NFD), with a .gitignore of `.claude/`. log_dir $HOME/Café/proj/.claude/wlogs is
# not made yet and git ignores it (`git check-ignore -q --no-index` exits 0). The watcher
# writes its rows there and status has no refusal. A stdin check-ignore dies on that path
# ("Invalid path": git precomposes its work tree but not stdin paths), the check reads
# unknown, and the root is refused on every call (the watcher never makes it).
my $nfd = "Cafe\xcc\x81";
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$HOME/' . $nfd . '/proj/.claude/wlogs');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $w = "$v->{HOME}/$nfd/proj";
              watch::io::mkdir_p($w);
              system('git', 'init', '-q', $w) == 0 or die "git init failed\n";
              open(my $fh, '>', "$w/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my $home = $E->var('HOME');
        my $log = "$home/$nfd/proj/.claude/wlogs";
        $E->count([ $E->rows("$log/" . $E->var('SID') . '.classic.jsonl', 'precompact') ], 1,
                  'watcher precompact row in log_dir');
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt !~ /refused|writes nothing/), "status has no refusal: $txt");
    },
};

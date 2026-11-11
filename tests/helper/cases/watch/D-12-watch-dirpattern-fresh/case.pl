# Unsafe roots: a fresh install in a dotfiles home that ignores the
# default handoff root with a folder-only pattern (`.local/state/<plugin>/handoffs/`); the root is not made
# yet. The root is git-ignored, so it is ok from the first call on: every PreCompact (the
# library call and both launcher calls) leaves its row, and `status` has no refusal. Before the
# fix the first calls were refused as root-in-git until core's own write made the folder.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
{
    needs => ['cmd:git'],
    needs_note => 'the ignored-root test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".local/state/$T::BRAND/handoffs/\n";
              close $fh;
          } },
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1 },
        { call => 'cli', at => 41, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1 },
        { call => 'status', at => 42 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->rows('classic', 'precompact') ], 3, 'precompact rows (library call and two launcher calls)');
        my @o = $E->outputs;
        my $all = ref $o[-1] eq 'ARRAY' ? join("\n", @{ $o[-1] }) : '';
        $E->ok(scalar($all !~ /writes nothing/), "no refusal line in status: $all");
    },
};

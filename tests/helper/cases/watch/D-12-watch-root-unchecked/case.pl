# Unsafe roots: `root-unchecked` refuses for one call only. HOME is
# a dotfiles repository that ignores .claude/ and .local/state/<plugin>/ (an ok root), but this helper call's root-check
# deadline ($roots::DEADLINE) has already passed, so git check-ignore cannot run: the library
# PreCompact writes nothing and `status` says root-unchecked. A later launcher call (its own
# deadline and roots cache) checks again and writes.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my $rows = 0;
{
    needs => ['cmd:git'],
    needs_note => 'the ignored-root test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\n";
              close $fh;
              $roots::DEADLINE = 1;    # epoch ms: long past
          } },
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'status', at => 10 },
        { call => 'code', code => sub {
              my ($v) = @_;
              $roots::DEADLINE = undef;
              my $r = watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.classic.jsonl");
              $rows = scalar grep { ($_->{ev} // '') eq 'precompact' } @$r;
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        $roots::DEADLINE = undef;
        $E->is($rows, 0, 'no precompact row from the out-of-time call');
        my ($lines) = $E->outputs;
        my $all = ref $lines eq 'ARRAY' ? join("\n", @$lines) : '';
        $E->ok(scalar($all =~ /^Watcher: writes nothing \(log_dir: root-unchecked\)$/m), "status says root-unchecked: $all");
        $E->count([ $E->rows('classic', 'precompact') ], 1, 'the later launcher call writes its precompact row');
    },
};

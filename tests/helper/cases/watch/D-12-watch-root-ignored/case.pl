# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1), the control of D-12-watch-root-in-git: the home
# folder is a dotfiles git repository that ignores .claude/ and .local/state/<plugin>/, so the handoff root and its
# .watch folder are git-ignored and ok. The watcher writes as before (the PreCompact,
# PostCompact and sweep rows) and `status` has no refusal line; through the real launcher
# core logs its root_in_git {ignored: true} rows beside the watcher's.
my $n = 'd12b0001';
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my $body = "<summary>\n${o}$T::BRAND v1 n=$n s=main${c}\n## Resume here\nStep 1: done\n${o}/$T::BRAND n=$n${c}\n</summary>";
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
{
    needs => ['cmd:git'],
    needs_note => 'the ignored-root test asks git check-ignore',
    transcript => [ T::prompt(0), T::boundary(10, trigger => 'auto'), T::summary(10.1), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\n";
              close $fh;
          } },
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'ok', normalized => $body } } },
        { call => 'stop', at => 30 },
        { call => 'status', at => 31 },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->rows('classic', 'precompact') ], 2, 'precompact rows (library call and launcher)');
        $E->count([ $E->rows('classic', 'postcompact') ], 1, 'postcompact row');
        $E->ok(scalar($E->boundaries) >= 1, 'the sweep row holds the boundary');
        $E->count([ $E->rows('classic', 'watch_error') ], 0, 'no watch_error row');
        my @g = $E->rows('classic', 'root_in_git');
        $E->ok(@g && !grep({ !Checker::truthy($_->{ignored}) } @g), "core's root_in_git rows say ignored");
        my ($lines) = $E->outputs;
        my $all = ref $lines eq 'ARRAY' ? join("\n", @$lines) : '';
        $E->ok(scalar($all !~ /writes nothing/), "no refusal line in status: $all");
        $E->ok(scalar($all =~ /^Watcher: shadow;/m), "status: watcher shadow: $all");
    },
};

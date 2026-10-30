# WATCH §6.1 (MOD-SPEC §1.2 D-12 unsafe roots; H-1): a home folder that is a dotfiles git
# repository puts the default handoff root and its .watch folder inside a work tree that does
# not ignore them (root-in-git). The watcher then writes nothing: no rows, no alerts, no
# session folders, from on_hook, on_stop and through the real launcher (where core passes no
# watch dir, since log_dir and its default are both refused), and `status` says why. Before
# H-1's fix watch::ctx::refused read roots::check's per-root result as a string and never
# refused. D-12-watch-root-ignored is the control: the same repository ignoring .claude/.
my $n = 'd12a0001';
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my $body = "<summary>\n${o}$T::BRAND v1 n=$n s=main${c}\n## Resume here\nStep 1: done\n${o}/$T::BRAND n=$n${c}\n</summary>";
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my $tree = sub {
    my ($d) = @_;
    my @out;
    my @q = ($d);
    while (@q) {
        my $x = shift @q;
        opendir(my $dh, $x) or next;
        for my $e (grep { !/\A\.\.?\z/ } readdir $dh) { push @out, "$x/$e"; push @q, "$x/$e" if -d "$x/$e" }
    }
    return @out;
};
{
    needs => ['cmd:git'],
    needs_note => 'the root-in-git test asks git check-ignore',
    transcript => [ T::prompt(0), T::boundary(10, trigger => 'auto'), T::summary(10.1), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
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
        my @w = $tree->($E->var('WATCH'));
        $E->is(join(' ', @w), '', 'nothing written under the watch dir');
        my @r = $tree->($E->var('ROOT'));
        $E->is(join(' ', @r), '', 'nothing written under the handoff root');
        my ($lines) = $E->outputs;
        my $all = ref $lines eq 'ARRAY' ? join("\n", @$lines) : '';
        $E->ok(scalar($all =~ /^Watcher: writes nothing \(log_dir: root-in-git\)$/m), "status says why: $all");
    },
};

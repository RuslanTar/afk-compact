# Unsafe roots: the handoff root alone is refused. log_dir lies
# outside any work tree (ok), while HOME is a dotfiles git repository that does not ignore
# .claude/, so the default handoff root is root-in-git. Through the real launcher core still
# logs to log_dir (its own rows and session folder), but the watcher writes nothing there:
# no precompact row, no alerts or other watcher file. `status` names the handoff root.
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my %env = (CLAUDE_PLUGIN_OPTION_LOG_DIR => '$TMP/wlogs');
my $sid_files = sub {
    my ($d, $sid) = @_;
    opendir(my $dh, $d) or return ();
    return grep { index($_, $sid) == 0 } readdir $dh;
};
{
    needs => ['cmd:git'],
    needs_note => 'the root-in-git test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
          } },
        { call => 'cli', at => 40, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, any_stdout => 1, env => \%env },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%env },
    ],
    expect => sub {
        my ($E) = @_;
        my ($d, $sid) = ($E->var('TMP') . '/wlogs', $E->var('SID'));
        # core still logs to log_dir (an ok root): its classic file and session folder only
        my @w = grep { $_ ne "$sid.classic.jsonl" && $_ ne $sid } $sid_files->($d, $sid);
        $E->is(join(' ', @w), '', 'no watcher file for the session in log_dir');
        my $cl = "$d/$sid.classic.jsonl";
        $E->ok(scalar(grep { ($_->{key} // '') eq 'handoff_root' } $E->rows($cl, 'root_in_git')),
               "core logged the handoff root's refusal in log_dir");
        $E->count([ $E->rows($cl, 'precompact') ], 0, 'no watcher precompact row');
        opendir(my $dh, "$d/$sid") or die "no session folder: $!";
        my @sd = grep { !/\A(?:\.\.?|once|dispatch)\z/ } readdir $dh;
        $E->is(join(' ', @sd), '', "only core's folders in the session folder");
        my @o = $E->outputs;
        my $txt = ref $o[-1] eq 'HASH' ? ($o[-1]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^Watcher: writes nothing \(handoff_root: root-in-git\)$/m), "status names the handoff root: $txt");
    },
};

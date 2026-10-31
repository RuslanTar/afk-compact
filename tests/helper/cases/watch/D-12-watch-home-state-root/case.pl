# WATCH §6.1 (MOD-SPEC §1.2 D-12; STATE-ROOT 0.1.2): HOME is a git work tree (a dotfiles
# repository) whose .gitignore ignores only .claude/, which kept the handoff root of 0.1.1
# (~/.claude/handoffs) out of git. The default root is now ~/.local/state/<plugin>/handoffs,
# which nothing ignores, so it is refused as root-in-git (the guard is right: files written there
# would show in git status), and with it the watcher's default log folder. `status` names the
# root as in git, its work tree, and the two ways out: ignore ~/.local/state/<plugin>/ (the line
# for ~/.gitignore), or set handoff_root and disposable_root (folders). With disposable_root set
# outside the work tree only handoff_root is left to set (a folder). Once that line is added, the
# next status refuses nothing.
my $b = quotemeta $T::BRAND;
my $made;
my %disp = (CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT => '$TMP/disp');
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n";
              close $fh;
          } },
        { call => 'cli', at => 40, argv => ['status', '--sid', '$SID'], any_stdout => 1 },
        { call => 'cli', at => 40.5, argv => ['status', '--sid', '$SID'], any_stdout => 1, env => \%disp },
        { call => 'code', code => sub {
              my ($v) = @_;
              $made = -e $v->{ROOT} ? 1 : 0;
              open(my $fh, '>>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".local/state/$T::BRAND/\n";
              close $fh;
          } },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = grep { ref $_ eq 'HASH' } $E->outputs;
        my $txt = defined $o[0] ? ($o[0]{stdout} // '') : '';
        my $one = defined $o[1] ? ($o[1]{stdout} // '') : '';
        my $after = defined $o[2] ? ($o[2]{stdout} // '') : '';
        $E->ok(scalar($txt =~ /^root: handoff_root refused \(root-in-git\); copies and evidence under it are not written$/m),
               "status: handoff_root refused as root-in-git: $txt");
        my ($fix) = $txt =~ /^(  in git, not ignored: .*)$/m;
        $fix //= '';
        $E->ok(scalar($fix =~ m{: ~/\.local/state/$b/handoffs[,( ]}), "the fix line names the new root: $fix");
        $E->ok(scalar($fix =~ m{ \(work tree ~\); }), "the fix line names the home work tree: $fix");
        $E->ok(scalar($fix =~ m{; to fix, ignore ~/\.local/state/$b/ there \(the line /\.local/state/$b/ in ~/\.gitignore\)}),
               "the fix line says to ignore ~/.local/state/<plugin>/: $fix");
        $E->ok(scalar($fix =~ m{, or set handoff_root and disposable_root in /config to folders outside any git work tree$}),
               "the fix line says to set handoff_root and disposable_root: $fix");
        $E->ok(scalar($fix !~ /\blog_dir\b/), "log_dir (unset, it follows handoff_root) is not a key to set: $fix");
        my ($fix1) = $one =~ /^(  in git, not ignored: .*)$/m;
        $fix1 //= '';
        $E->ok(scalar($one !~ /^root: disposable_root refused/m), "disposable_root outside the work tree is not refused: $one");
        $E->ok(scalar($fix1 =~ m{, or set handoff_root in /config to a folder outside any git work tree$}),
               "one key to set, a folder: $fix1");
        $E->is($made, 0, "the refused root is not made");
        $E->ok(scalar($after !~ /refused|in git, not ignored|no log folder/), "with the state folder ignored, no refusal: $after");
    },
};

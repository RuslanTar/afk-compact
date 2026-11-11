# Unsafe roots: a work tree at or under the state folder
# (~/.local/state/<plugin>). `git init` in the default handoff root makes the root its own work
# tree: ignoring a folder there cannot help, so `status` gives only the key to set, and the
# watcher's default log folder (.watch under the root, unset log_dir) joins that line. Then
# `git init` in the state folder itself: the default disposable root sits inside it, so its line
# names its own path and the .gitignore line for it, not the state folder (which is the work tree).
my $b = quotemeta $T::BRAND;
my $s = "~/\\.local/state/$b";
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{ROOT}) == 0 or die "git init failed\n";
          } },
        { call => 'cli', at => 40, argv => ['status', '--sid', '$SID'], any_stdout => 1 },
        { call => 'code', code => sub {
              my ($v) = @_;
              (my $state = $v->{ROOT}) =~ s{/[^/]+\z}{};
              system('git', 'init', '-q', $state) == 0 or die "git init failed\n";
          } },
        { call => 'cli', at => 41, argv => ['status', '--sid', '$SID'], any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = grep { ref $_ eq 'HASH' } $E->outputs;
        my $one = defined $o[0] ? ($o[0]{stdout} // '') : '';
        my $two = defined $o[1] ? ($o[1]{stdout} // '') : '';
        my @fix1 = $one =~ /^(  in git, not ignored: .*)$/mg;
        $E->ok(scalar($one =~ /^root: handoff_root refused \(root-in-git\)/m), "handoff_root refused: $one");
        $E->ok(scalar($one =~ /^root: log_dir refused \(root-in-git\)/m), "log_dir refused: $one");
        $E->ok(scalar($one !~ /^root: disposable_root refused/m), "disposable_root not refused: $one");
        $E->is(scalar(@fix1), 1, "one fix line: @fix1");
        $E->ok(scalar(($fix1[0] // '') =~ m{^  in git, not ignored: $s/handoffs, $s/handoffs/\.watch \(work tree $s/handoffs\); to fix, set handoff_root in /config to a folder outside any git work tree$}),
               "the root is its work tree: set handoff_root only: @fix1");
        my @fix2 = $two =~ /^(  in git, not ignored: .*)$/mg;
        $E->ok(scalar($two =~ /^root: disposable_root refused \(root-in-git\)/m), "disposable_root refused: $two");
        $E->is(scalar(@fix2), 2, "two fix lines: @fix2");
        $E->is($fix2[0] // '', $fix1[0] // '', 'the handoff root keeps its own work tree');
        $E->ok(scalar(($fix2[1] // '') =~ m{^  in git, not ignored: $s/disposable \(work tree $s\); to fix, ignore $s/disposable/ there \(the line /disposable/ in $s/\.gitignore\), or set disposable_root in /config to a folder outside any git work tree$}),
               "inside the state work tree: the root's own path and line: @fix2");
    },
};

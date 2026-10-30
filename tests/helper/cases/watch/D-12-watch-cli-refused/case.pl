# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1 review finding 3): the watcher's command-line writers
# check the roots as its hooks do. The home folder is a dotfiles git repository that does not
# ignore .claude/, so the handoff root and its .watch folder are root-in-git. `watch prune`,
# `watch report` (default reports/ folder), `watch report --export` (the salt) and `report`
# (salt, install id, report_withheld rows) print `REFUSED: log_dir: root-in-git` and exit 3;
# nothing under the handoff root is written, changed or deleted. `report --dry-run` writes
# nothing anyway and still runs.
my $old = $T::BASE + 3600 - 40 * 86400;
my $A = 'aaaaaaaa-1111-4111-8111-11111111d12c';
my $tree = sub {
    my ($d) = @_;
    my @out;
    my @q = ($d);
    while (@q) {
        my $x = shift @q;
        opendir(my $dh, $x) or next;
        for my $e (grep { !/\A\.\.?\z/ } readdir $dh) {
            my @st = lstat "$x/$e";
            push @out, "$x/$e:" . ($st[7] // '?') . ':' . ($st[9] // '?');
            push @q, "$x/$e" if -d "$x/$e" && !-l "$x/$e";
        }
    }
    return join(' ', sort @out);
};
my $before;
my $refused = qr/\AREFUSED: log_dir: root-in-git\n\z/;
{
    needs => ['cmd:git'],
    needs_note => 'the root-in-git test asks git check-ignore',
    files => [
        { path => "\$WATCH/$A.classic.jsonl", text => "{\"v\":1}\n", mtime => $old },
        { path => "\$WATCH/$A.jsonl", text => "{}\n", mtime => $old },
    ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              $before = $tree->($v->{ROOT});
          } },
        { call => 'cli', argv => ['watch', 'prune', '--days', '30'], exit => 3, stdout_re => $refused },
        { call => 'cli', argv => ['watch', 'report'], exit => 3, stdout_re => $refused },
        { call => 'cli', argv => ['watch', 'report', '--export'], exit => 3, stdout_re => $refused },
        { call => 'cli', argv => ['report'], exit => 3, stdout_re => $refused },
        { call => 'cli', argv => ['report', '--dry-run'], exit => 0, stdout_re => qr/^REPORT .*\(dry run: nothing written\)$/m },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(length($before // ''), 'the handoff root held the old session set before the commands');
        $E->is($tree->($E->var('ROOT')), $before, 'nothing under the handoff root written, changed or deleted');
    },
};

# Unsafe roots: no watch_error row under a refused root. HOME is a
# dotfiles git repository that does not ignore .claude/ (root-in-git), and the hook dies in
# watcher_on, before its own refusal check: error_row checks the roots itself and writes
# nothing. Without that check a watch_error row lands in <root>/.watch/<sid>.classic.jsonl.
my $saved;
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
my $restore = sub {
    return unless $saved;
    no warnings 'redefine';
    *watch::ctx::watcher_on = $saved;
    $saved = undef;
};
{
    needs => ['cmd:git'],
    needs_note => 'the root-in-git test asks git check-ignore',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              require watch::ctx;
              $saved = \&watch::ctx::watcher_on;
              no warnings 'redefine';
              *watch::ctx::watcher_on = sub { die "boom-test\n" };
          } },
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'code', code => sub { $restore->() } },
    ],
    expect => sub {
        my ($E) = @_;
        $restore->();
        my @r = $tree->($E->var('ROOT'));
        $E->is(join(' ', @r), '', 'nothing written under the handoff root');
    },
};

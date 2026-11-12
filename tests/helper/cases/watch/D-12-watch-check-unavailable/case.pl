# Unsafe roots: a root check that cannot run refuses, since unknown is
# not safe. HOME is a dotfiles repository that ignores .claude/ and .local/state/<plugin>/ (an ok root), but
# roots::check_path has no body for this call (roots.pm loaded, the sub swapped out), so the library
# PreCompact writes nothing and `status` says check-unavailable.
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
    *roots::check_path = $saved;
    $saved = undef;
};
{
    needs => ['cmd:git'],
    needs_note => 'the home work tree ignores .claude/ and .local/state/<plugin>/ (git check-ignore)',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n.local/state/$T::BRAND/\n";
              close $fh;
              require 'util.pm';
              require 'git.pm';
              require 'roots.pm';
              $saved = \&roots::check_path;
              # a sub that is named but has no body: `defined &roots::check_path` reads false,
              # and the saved original stays whole
              no warnings 'redefine';
              *roots::check_path = \&roots::check_path_absent_in_test;
          } },
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'status', at => 10 },
        { call => 'code', code => sub { $restore->() } },
    ],
    expect => sub {
        my ($E) = @_;
        $restore->();
        my @r = $tree->($E->var('ROOT'));
        $E->is(join(' ', @r), '', 'nothing written under the handoff root');
        my ($lines) = $E->outputs;
        my $all = ref $lines eq 'ARRAY' ? join("\n", @$lines) : '';
        $E->ok(scalar($all =~ /^Watcher: writes nothing \(roots: check-unavailable\)$/m), "status says check-unavailable: $all");
    },
};

# Unsafe roots: roots::check_path dies (swapped for a sub that dies)
# in a home that ignores .claude/ and .local/state/<plugin>/ (an ok root): refused() says `check-failed`, and the library
# PreCompact writes nothing under the handoff root. Skipping the failed root instead writes
# .watch/<sid>.classic.jsonl.
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
    needs_note => 'the root check asks git check-ignore',
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
              no warnings 'redefine';
              *roots::check_path = sub { die "boom-test\n" };
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
        $E->ok(scalar($all =~ /check-failed/), "status says check-failed: $all");
    },
};

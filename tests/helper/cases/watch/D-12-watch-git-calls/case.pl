# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): a root check asks git once. HOME is a dotfiles
# repository that ignores .claude/. roots::check_path on a root that exists runs one
# `git check-ignore`, and on a root not made yet also one (both forms go in one -z --stdin
# call). Each check is counted from the test trace's `git` lines. D-12-watch-root-form only
# compares runs with each other; this pins the count, which PreCompact's 500 ms budget needs.
my %n;
my $calls = sub {
    my ($v, $path) = @_;
    my $f = "$v->{TMP}/trace-" . (scalar(keys %n) + 1) . '.log';
    local $ENV{STORE_TEST_TRACE} = $f;
    # HOME-GUARD: %ENV changed since the driver checked it; the root check starts git with it
    homeguard::check(\%ENV, q(check_path));
    my $r = roots::check_path($path);
    my $t = watch::io::slurp($f) // '';
    my $c = () = $t =~ /^git$/mg;
    return ($c, $r);
};
{
    needs => ['cmd:git'],
    needs_note => 'the root check asks git check-ignore',
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh ".claude/\n";
              close $fh;
              require 'util.pm';
              require 'git.pm';
              require 'roots.pm';
              git::available();    # the macOS git guard's own probe is not a check-ignore
              watch::io::mkdir_p("$v->{HOME}/.claude/made-root");
              @{ $n{made} } = $calls->($v, "$v->{HOME}/.claude/made-root");
              @{ $n{new} } = $calls->($v, "$v->{HOME}/.claude/new-root");
          } },
    ],
    expect => sub {
        my ($E) = @_;
        for my $k (qw(made new)) {
            my ($c, $r) = @{ $n{$k} || [] };
            $E->is($c, 1, "$k root: one git call");
            $E->ok(ref $r eq 'HASH' && $r->{ok} && $r->{ignored}, "$k root: ok and ignored");
        }
    },
};

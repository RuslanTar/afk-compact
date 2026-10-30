# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): the root check itself dies (watch::ctx::_root_refusal
# swapped for a sub that dies) in a home that ignores .claude/ and .local/state/<plugin>/ (an ok root). The hook dies in
# refused(), error_row asks refused() again, it dies again: unknown is not safe, so no
# watch_error row. Reading the undefined answer as "not refused" writes one.
my $saved;
my $restore = sub {
    return unless $saved;
    no warnings 'redefine';
    *watch::ctx::_root_refusal = $saved;
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
              require watch::ctx;
              $saved = \&watch::ctx::_root_refusal;
              no warnings 'redefine';
              *watch::ctx::_root_refusal = sub { die "boom-test\n" };
          } },
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'code', code => sub { $restore->() } },
    ],
    expect => sub {
        my ($E) = @_;
        $restore->();
        $E->count([ $E->rows("\$WATCH/" . $E->var('SID') . '.classic.jsonl', 'watch_error') ], 0, 'no watch_error row');
    },
};

# WATCH §6.1 (MOD-SPEC §1.2 D-12; H-1): git::check_ignore_forms reads four NUL-terminated
# fields per path asked. Output of any other length is the wrong shape and reads unknown
# (undef), so roots::check_path refuses the root (root-in-git). git::cmd is swapped for a sub
# that prints canned output: three records for two paths, each naming the folder-only pattern
# `wlogs/` (read without the count check, the root would pass as ignored), and one record for
# two paths. Eight fields, the right shape, still read as ignored.
my $saved;
my $out;
my %got;
my $rec = ".gitignore\0" . "1\0" . "wlogs/\0" . "./wlogs/\0";
my $restore = sub {
    return unless $saved;
    no warnings 'redefine';
    *git::cmd = $saved;
    $saved = undef;
};
{
    needs => ['cmd:git'],
    needs_note => 'the root check walks up to a git work tree',
    transcript => [ T::prompt(0), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              system('git', 'init', '-q', $v->{HOME}) == 0 or die "git init failed\n";
              open(my $fh, '>', "$v->{HOME}/.gitignore") or die "gitignore: $!";
              print $fh "wlogs/\n";
              close $fh;
              require 'util.pm';
              require 'git.pm';
              require 'roots.pm';
              $saved = \&git::cmd;
              {
                  no warnings 'redefine';
                  *git::cmd = sub { return { exit => 0, out => $out, ms => 0 } };
              }
              my $forms = sub { my $a = git::check_ignore_forms($v->{HOME}, ['./wlogs', './wlogs/'], 2000);
                                return !defined $a ? 'undef' : ref $a eq 'ARRAY' ? 'array:' . join(',', map { $_->[0] } @$a) : "other:$a" };
              # the real git::cmd is back before this step ends, even when a check dies, so
              # the cases run after this one in the same process see real git
              my $ok = eval {
                  $out = $rec x 2;
                  $got{eight} = $forms->();
                  $out = $rec x 3;
                  $got{twelve} = $forms->();
                  $got{root_twelve} = roots::check_path("$v->{HOME}/wlogs")->{reason} // 'ok';
                  $out = $rec;
                  $got{four} = $forms->();
                  $got{root_four} = roots::check_path("$v->{HOME}/wlogs/")->{reason} // 'ok';
                  1;
              };
              my $err = $@;
              $restore->();
              die $err unless $ok;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $restore->();
        $E->is($got{eight} // '', 'array:1,1', 'eight fields for two paths: both read as ignored');
        $E->is($got{twelve} // '', 'undef', 'twelve fields for two paths: unknown');
        $E->is($got{four} // '', 'undef', 'four fields for two paths: unknown');
        $E->is($got{root_twelve} // '', 'root-in-git', 'a root asked with twelve fields back is refused');
        $E->is($got{root_four} // '', 'root-in-git', 'a root asked with four fields back is refused');
    },
};

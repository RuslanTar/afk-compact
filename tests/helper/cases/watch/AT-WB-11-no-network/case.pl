# AT-WB-11 (W-BETA; P-4; BUILD-ROUND-9 WCH-09): no network on the report path. Static: the
# report modules name no IO::Socket, LWP, HTTP::Tiny or Net::. Runtime: with socket and
# connect overridden to die (CORE::GLOBAL, set before the helper compiles), `report`
# still writes its zip and exits 0.
use Cwd ();
use File::Basename ();
my $helper = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin/helper');
my %got;
{
    allow_canary => 1,
    files => T::beta_install(),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{TMP}/out");
              my $main = File::Basename::dirname(main::cli_launcher()) . '/../helper/main.pl';
              my $prog = 'BEGIN { *CORE::GLOBAL::socket = sub { die "socket called\n" }; '
                       . '*CORE::GLOBAL::connect = sub { die "connect called\n" } } my $m = shift @ARGV; do $m; die $@ if $@;';
              local $ENV{STORE_TEST_NO_GIT} = '1';
              my $q = sub { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" };
              $got{out} = `perl -e @{[ $q->($prog) ]} @{[ $q->($main) ]} report --out @{[ $q->("$v->{TMP}/out") ]} 2>&1`;
              $got{exit} = $? >> 8;
              $got{zips} = [ T::zips_in("$v->{TMP}/out") ];
          } },
    ],
    expect => sub {
        my ($E) = @_;
        for my $f ("$helper/lib/watch/export.pm", "$helper/lib/watch/export_schema.pm", "$helper/lib/watch/bundle.pm",
                   "$helper/cmd/report.pl") {
            my $src = watch::io::slurp($f) // '';
            $E->ok(($src !~ /\b(?:IO::Socket|LWP|HTTP::Tiny|Net::)/ ? 1 : 0), "$f names no network module");
        }
        $E->is($got{exit}, 0, "report runs with socket/connect dying ($got{out})");
        $E->is(scalar @{ $got{zips} || [] }, 1, 'and writes its zip');
    },
};

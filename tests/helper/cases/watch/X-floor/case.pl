# AT-P-11 for WP-watch's files (ROOT-RULINGS R-1, RUNTIME §2.4): every `use`
# or `require` is a floor module, a watcher module, or sits inside an `eval`
# with a fallback. No step; the check reads the source.
use Cwd ();
use File::Basename ();
my $helper = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin/helper');
my %floor = map { $_ => 1 } qw(strict warnings constant Fcntl POSIX Errno Cwd File::Spec File::Path File::Temp
                               File::Basename IPC::Open3 Getopt::Long IO::Handle List::Util Scalar::Util lib);
{
    steps => [],
    expect => sub {
        my ($E) = @_;
        my @files = ("$helper/lib/watch.pm", "$helper/cmd/watch.pl");
        opendir(my $d, "$helper/lib/watch") or die;
        push @files, map { "$helper/lib/watch/$_" } sort grep { /\.pm\z/ } readdir $d;
        my $n = 0;
        for my $f (@files) {
            open(my $fh, '<', $f) or die "$f: $!";
            while (my $l = <$fh>) {
                next unless $l =~ /^\s*(?:use|require)\s+([A-Za-z_][\w:]*)/ || $l =~ /\brequire\s+([A-Z][\w:]*)/;
                my $m = $1;
                $n++;
                next if $floor{$m} || $m =~ /\Awatch(?:::|\z)/ || $m eq 'utf8';
                next if $l =~ /\beval\s*\{[^}]*\brequire\s+\Q$m\E/;
                $E->ok(0, "$f:$.: $m is not a floor module and not inside eval");
            }
        }
        $E->ok($n > 20, "scanned $n use/require lines");
    },
};

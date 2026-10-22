# AT-P5-05, watcher half (P5-FOLD A4; BUILD-ROUND-9 WCH-04): every WP-watch source file
# declares `use utf8`, so a later non-ASCII literal is a character, never two or three bytes
# read as Latin-1 (one rule, no exceptions: comment-only files too). The pragma sits right
# after `use warnings;`, before any other code. No step; the check reads the source.
use Cwd ();
use File::Basename ();
my $helper = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin/helper');
{
    steps => [],
    expect => sub {
        my ($E) = @_;
        my @files = ("$helper/lib/watch.pm", "$helper/cmd/watch.pl");
        opendir(my $d, "$helper/lib/watch") or die;
        push @files, map { "$helper/lib/watch/$_" } sort grep { /\.p[ml]\z/ } readdir $d;
        my $nonascii = 0;
        for my $f (@files) {
            open(my $fh, '<:raw', $f) or die "$f: $!";
            my $src = do { local $/; <$fh> };
            close $fh;
            $nonascii++ if $src =~ /[^\x00-\x7f]/;
            $E->ok((utf8::decode(my $copy = $src) ? 1 : 0), "$f: not valid UTF-8");
            $E->ok(($src =~ /^use warnings;\nuse utf8;\n/m ? 1 : 0), "$f: no `use utf8;` right after `use warnings;`");
        }
        $E->ok($nonascii >= 10, "scanned files with non-ASCII text: $nonascii");
    },
};

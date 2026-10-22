# AT-P-11 for WP-watch's files (ROOT-RULINGS R-1, RUNTIME §2.4; PKG-RUNTIME B.2 L1-L3).
# L1 modules: every `use` or `require` is a floor module, a watcher module, or sits inside
# an `eval` with a fallback. L2 implicit loads: `%+`, `%-`, `$+{`, `$-{`
# (Tie::Hash::NamedCapture, missing in Debian 10 perl-base), `\N{NAME}` (charnames),
# `\p{..}`/`\P{..}` (Unicode tables perl-base trims), `use open`, `Encode::`. L3 version:
# `use v5.N`/`use 5.0NN` above the 5.28 floor, `use feature` with a post-5.28 feature, any
# `builtin::` call. Every finding line carries the reason and the fix (PR-4 convention).
# Comment lines are not code. A seeded source with each construct must be flagged, so the
# lint cannot pass by matching nothing. No step; the check reads the source.
use Cwd ();
use File::Basename ();
my $helper = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin/helper');
my %floor = map { $_ => 1 } qw(strict warnings constant Fcntl POSIX Errno Cwd File::Spec File::Path File::Temp
                               File::Basename IPC::Open3 Getopt::Long IO::Handle List::Util Scalar::Util lib);
my $FLOOR = 5.028;
my @L2 = (
    [ qr/(?:\$[+-]\{|(?<![\w\$\@%'"])%[+-](?=[\s;,)}\]]|\z))/, '%+/%-/$+{/$-{ loads Tie::Hash::NamedCapture, which perl-base 5.28 (Debian 10) lacks',
      'numbered captures ($1, $2)' ],
    [ qr/\\N\{(?!U\+)[A-Za-z]/, '\N{NAME} loads charnames, which perl-base may lack', '\x{....} with the code point' ],
    [ qr/\\[pP]\{/, '\p{..}/\P{..} needs the Unicode property tables, which perl-base trims', 'an explicit character class' ],
    [ qr/^\s*use\s+open\b/, '`use open` loads the open pragma and PerlIO layers perl-base may lack', 'binmode or :raw on each handle' ],
    [ qr/\bEncode::/, 'Encode is not in perl-base', 'utf8::encode / utf8::decode (built in)' ],
);
my %NEW_FEATURE = map { $_ => 1 } qw(isa try defer class module_true extra_paired_delimiters signatures);

sub lint {
    my ($name, $src) = @_;
    my @out;
    my $ln = 0;
    for my $l (split /\n/, $src) {
        $ln++;
        next if $l =~ /^\s*#/;
        if ($l =~ /^\s*(?:use|require)\s+([A-Za-z_][\w:]*)/ || $l =~ /\brequire\s+([A-Z][\w:]*)/) {
            my $m = $1;
            unless ($m =~ /\Av[0-9]/ || $floor{$m} || $m =~ /\Awatch(?:::|\z)/ || $m eq 'utf8' || $m eq 'feature' || $m eq 'open'
                    || $l =~ /\beval\s*\{[^}]*\brequire\s+\Q$m\E/) {
                push @out, "$name:$ln: $m is not a floor module and not inside eval. Fix: a floor module, or require it inside eval with a fallback.";
            }
        }
        for my $r (@L2) {
            push @out, "$name:$ln: $r->[1]. Fix: $r->[2]." if $l =~ $r->[0];
        }
        if ($l =~ /^\s*use\s+v?(5)\.([0-9]+)(?:\.([0-9]+))?/) {
            my $v = length($2) >= 3 && !defined $3 && $l !~ /use\s+v/ ? "5.$2" + 0 : 5 + $2 / 1000;
            push @out, "$name:$ln: use $1.$2 asks for a perl above the 5.28 floor. Fix: drop it; the helper targets 5.28."
                if $v > $FLOOR + 1e-9;
        }
        if ($l =~ /^\s*use\s+feature\b(.*)/) {
            my @f = grep { $NEW_FEATURE{$_} } $1 =~ /([a-z_]+)/g;
            push @out, "$name:$ln: use feature '$_' is newer than perl 5.28. Fix: write it without the feature." for @f;
        }
        push @out, "$name:$ln: builtin:: functions arrived after perl 5.28. Fix: Scalar::Util or plain perl." if $l =~ /\bbuiltin::/;
    }
    return @out;
}

{
    steps => [],
    expect => sub {
        my ($E) = @_;
        my @files = ("$helper/lib/watch.pm", "$helper/cmd/watch.pl");
        opendir(my $d, "$helper/lib/watch") or die;
        push @files, map { "$helper/lib/watch/$_" } sort grep { /\.pm\z/ } readdir $d;
        my $n = 0;
        for my $f (@files) {
            open(my $fh, '<:raw', $f) or die "$f: $!";
            my $src = do { local $/; <$fh> };
            close $fh;
            $n += () = $src =~ /^\s*(?:use|require)\s/mg;
            (my $short = $f) =~ s{\A\Q$helper\E/}{};
            $E->ok(0, $_) for lint($short, $src);
        }
        $E->ok($n > 20, "scanned $n use/require lines");
        # Seeded constructs: each one is flagged once, with a reason and a fix.
        my @seed = (
            'my $t = $+{f};', 'for (keys %+) { }', 'my %h = %-;', 'my $x = $-{n}[0];',
            'my $s = "\N{EM DASH}";', '/\p{L}/', 'my $r = qr/\P{Lu}/;', 'use open qw(:std :utf8);',
            'Encode::decode("UTF-8", $b);', 'use v5.36;', 'use 5.032;', "use feature 'signatures';",
            'use feature qw(say try);', 'my $b = builtin::true;', 'use JSON::PP;',
        );
        for my $s (@seed) {
            my @hit = lint('seed.pm', $s);
            $E->is(scalar(@hit), 1, "seeded `$s` flagged once");
            $E->ok(($hit[0] =~ /\Aseed\.pm:1: .+\. Fix: .+\.\z/ ? 1 : 0), "seeded `$s`: reason and fix ($hit[0])") if @hit;
        }
        # Not flagged: sprintf formats, \N (no brace), \N{U+..}, the floor itself, comments, eval'd optional modules.
        for my $s ('sprintf("%-5s|%+d", $a, $b);', '/\N+/', 'my $s = "\N{U+00B7}";', 'use 5.028;', 'use v5.28;',
                   '# $+{f} in a comment', 'my $h = eval { require Digest::SHA; 1 };', "use feature 'say';", 'my %h = (a => 1);') {
            my @hit = lint('ok.pm', $s);
            $E->is(scalar(@hit), 0, "`$s` not flagged" . (@hit ? ": $hit[0]" : ''));
        }
    },
};

package frontmatter;
# lib/frontmatter.pm: YAML-subset frontmatter for copies and handoffs. Owner: WP-core.
#   write(\@pairs) -> "---\n<key>: <value>\n...---\n" (undef and '' values omitted;
#     plain scalars when safe, else JSON-quoted strings, which YAML reads too;
#     hashes and arrays as JSON flow values)
#   read(text) -> ({key => value}, body) or () when there is no valid frontmatter.
#     Values come back as strings, or as data for flow values.
use strict;
use warnings;
use utf8;

my $PLAIN = qr/^[A-Za-z0-9_~\/][A-Za-z0-9_.:\/@+~ ,()=-]*$/;

sub _scalar {
    my ($v) = @_;
    return jsonc::encode($v) if ref $v;
    my $s = "$v";
    return $s if $s =~ $PLAIN && $s !~ /\s$/ && $s !~ /: / && $s !~ / #/;
    return jsonc::encode($s);
}

sub write {
    my ($pairs) = @_;
    my $out = "---\n";
    for (my $i = 0; $i < @$pairs; $i += 2) {
        my ($k, $v) = ($pairs->[$i], $pairs->[$i + 1]);
        next if !defined $v || (!ref $v && $v eq '');
        $out .= "$k: " . _scalar($v) . "\n";
    }
    return $out . "---\n";
}

sub read {
    my ($text) = @_;
    return () unless defined $text;
    utf8::decode($text) unless utf8::is_utf8($text);
    return () unless $text =~ /\A---\n(.*?)\n---\n(.*)\z/s;
    my ($head, $body) = ($1, $2);
    my %h;
    for my $line (split /\n/, $head) {
        next if $line =~ /^\s*$/;
        return () unless $line =~ /^([A-Za-z0-9_]+): (.*)$/;
        my ($k, $v) = ($1, $2);
        if ($v =~ /^["\[{]/) {
            my $d = eval { jsonc::decode($v) };
            return () if $@;
            $h{$k} = $d;
        } else {
            $h{$k} = $v;
        }
    }
    return (\%h, $body);
}

1;

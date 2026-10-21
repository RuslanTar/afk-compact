package watch::json;
# lib/watch/json.pm: the watcher's JSON codec (floor modules only, RUNTIME §4).
# Owner: WP-watch. Strings stay UTF-8 byte strings in and out: \uXXXX escapes
# (and surrogate pairs) decode to UTF-8 bytes, and encode passes bytes >= 0x80
# through. Booleans decode to 1 and 0; encode writes \1 and \0 as true and false.
# Encode is canonical: object keys sorted, no spaces.
use strict;
use warnings;

sub decode {
    my ($text) = @_;
    die "json: undefined input\n" unless defined $text;
    my $s = $text;
    pos($s) = 0;
    $s =~ /\G[ \t\r\n]*/gc;
    my $v = _value(\$s);
    $s =~ /\G[ \t\r\n]*/gc;
    die "json: trailing data at " . pos($s) . "\n" if pos($s) != length($s);
    return $v;
}

sub _value {
    my ($r) = @_;
    $$r =~ /\G[ \t\r\n]*/gc;
    if ($$r =~ /\G\{/gc) {
        my %h;
        $$r =~ /\G[ \t\r\n]*/gc;
        return \%h if $$r =~ /\G\}/gc;
        while (1) {
            $$r =~ /\G[ \t\r\n]*/gc;
            die "json: object key expected at " . pos($$r) . "\n" unless $$r =~ /\G"/gc;
            my $k = _string($r);
            $$r =~ /\G[ \t\r\n]*:/gc or die "json: ':' expected at " . pos($$r) . "\n";
            $h{$k} = _value($r);
            $$r =~ /\G[ \t\r\n]*/gc;
            next if $$r =~ /\G,/gc;
            last if $$r =~ /\G\}/gc;
            die "json: ',' or '}' expected at " . pos($$r) . "\n";
        }
        return \%h;
    }
    if ($$r =~ /\G\[/gc) {
        my @a;
        $$r =~ /\G[ \t\r\n]*/gc;
        return \@a if $$r =~ /\G\]/gc;
        while (1) {
            push @a, _value($r);
            $$r =~ /\G[ \t\r\n]*/gc;
            next if $$r =~ /\G,/gc;
            last if $$r =~ /\G\]/gc;
            die "json: ',' or ']' expected at " . pos($$r) . "\n";
        }
        return \@a;
    }
    return _string($r) if $$r =~ /\G"/gc;
    if ($$r =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/gc) {
        return 0 + $1;
    }
    return 1 if $$r =~ /\Gtrue/gc;
    return 0 if $$r =~ /\Gfalse/gc;
    return undef if $$r =~ /\Gnull/gc;
    die "json: value expected at " . pos($$r) . "\n";
}

my %ESC = ('"' => '"', '\\' => '\\', '/' => '/', b => "\x08", f => "\x0c", n => "\n", r => "\r", t => "\t");

sub _string {
    my ($r) = @_;
    my $out = '';
    while (1) {
        if ($$r =~ /\G([^"\\\x00-\x1f]++)/gc) {
            $out .= $1;
        } elsif ($$r =~ /\G"/gc) {
            return $out;
        } elsif ($$r =~ /\G\\u([0-9a-fA-F]{4})/gc) {
            my $cp = hex $1;
            if ($cp >= 0xD800 && $cp <= 0xDBFF && $$r =~ /\G\\u([dD][c-fC-F][0-9a-fA-F]{2})/gc) {
                $cp = 0x10000 + (($cp - 0xD800) << 10) + (hex($1) - 0xDC00);
            }
            $out .= _utf8_bytes($cp);
        } elsif ($$r =~ /\G\\(["\\\/bfnrt])/gc) {
            $out .= $ESC{$1};
        } else {
            die "json: bad string at " . pos($$r) . "\n";
        }
    }
}

sub _utf8_bytes {
    my ($cp) = @_;
    return chr($cp) if $cp < 0x80;
    return chr(0xC0 | ($cp >> 6)) . chr(0x80 | ($cp & 0x3F)) if $cp < 0x800;
    return chr(0xE0 | ($cp >> 12)) . chr(0x80 | (($cp >> 6) & 0x3F)) . chr(0x80 | ($cp & 0x3F))
        if $cp < 0x10000;
    return chr(0xF0 | ($cp >> 18)) . chr(0x80 | (($cp >> 12) & 0x3F))
        . chr(0x80 | (($cp >> 6) & 0x3F)) . chr(0x80 | ($cp & 0x3F));
}

sub encode {
    my ($v) = @_;
    return 'null' unless defined $v;
    my $ref = ref $v;
    if ($ref eq 'HASH') {
        return '{' . join(',', map { _str($_) . ':' . encode($v->{$_}) } sort keys %$v) . '}';
    }
    if ($ref eq 'ARRAY') {
        return '[' . join(',', map { encode($_) } @$v) . ']';
    }
    if ($ref eq 'SCALAR') {
        return $$v ? 'true' : 'false';
    }
    return 'null' if $ref;
    return _is_num($v) ? (0 + $v) . '' : _str($v);
}

# A scalar counts as a number when perl holds it as one (a bitwise xor of a
# number with itself gives "0"; of a string, NUL bytes) and it has JSON form.
sub _is_num {
    my ($v) = @_;
    no warnings;
    return 0 unless (($v ^ $v) eq '0');
    return $v =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\z/ ? 1 : 0;
}

sub _str {
    my ($s) = @_;
    $s =~ s/(["\\])/\\$1/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f\x7f])/sprintf('\\u%04x', ord $1)/ge;
    return '"' . $s . '"';
}

1;

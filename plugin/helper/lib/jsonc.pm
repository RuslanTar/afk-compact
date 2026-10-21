package jsonc;
# lib/jsonc.pm: embedded JSON codec (ROOT-RULINGS R-1: one code path, no JSON::PP).
# Owner: WP-core. Floor modules only.
#
# decode(TEXT) -> data. TEXT may be bytes (UTF-8) or characters; strings come
#   back as Perl character strings. A string that is all ASCII comes back without
#   the UTF-8 flag (SR 1.1): one non-ASCII character elsewhere in a document must not
#   make its ASCII values character strings, which then mix with the helper's byte
#   literals (`·`) and print double-encoded. true/false decode to
#   $jsonc::true()/$jsonc::false(). Dies "json: <reason> at <offset>" on bad input.
# encode(DATA) -> one line of JSON as a character string. Hash keys are sorted;
#   an ordered object is jsonc::obj(k => v, ...). Numbers are scalars that were
#   made as numbers (a string of digits stays a string). Non-ASCII is kept as
#   characters, control characters are escaped.
use strict;
use warnings;

{
    package jsonc::Bool;
    use overload
        'bool' => sub { ${ $_[0] } },
        '0+'   => sub { ${ $_[0] } },
        '""'   => sub { ${ $_[0] } ? 'true' : 'false' },
        '!'    => sub { ${ $_[0] } ? 0 : 1 },
        '=='   => sub { (${ $_[0] } ? 1 : 0) == (ref $_[1] ? (${ $_[1] } ? 1 : 0) : ($_[1] ? 1 : 0)) },
        'eq'   => sub { "$_[0]" eq "$_[1]" },
        fallback => 1;
}

our $true  = do { my $v = 1; bless \$v, 'jsonc::Bool' };
our $false = do { my $v = 0; bless \$v, 'jsonc::Bool' };

sub true  { $true }
sub false { $false }
sub bool  { $_[0] ? $true : $false }
sub is_bool { ref($_[0]) && ref($_[0]) eq 'jsonc::Bool' }

# Ordered object: jsonc::obj(k1 => v1, k2 => v2, ...)
sub obj { return bless [@_], 'jsonc::Obj' }

# ---------------------------------------------------------------- decode

sub decode {
    my ($text) = @_;
    die "json: undefined input\n" unless defined $text;
    if (!utf8::is_utf8($text)) {
        my $copy = $text;
        $text = $copy if utf8::decode($copy);
    }
    my $pos = 0;
    my $v = _value(\$text, \$pos, 0);
    _ws(\$text, \$pos);
    die "json: trailing text at $pos\n" if $pos < length $text;
    return $v;
}

sub _ws {
    my ($t, $p) = @_;
    pos($$t) = $$p;
    $$t =~ /\G[ \t\r\n]*/gc;
    $$p = pos($$t);
}

sub _value {
    my ($t, $p, $depth) = @_;
    die "json: nesting too deep at $$p\n" if $depth > 512;
    _ws($t, $p);
    my $c = substr($$t, $$p, 1);
    die "json: unexpected end at $$p\n" if $c eq '';
    if ($c eq '{') {
        $$p++;
        my %h;
        _ws($t, $p);
        if (substr($$t, $$p, 1) eq '}') { $$p++; return \%h }
        while (1) {
            _ws($t, $p);
            die "json: expected string key at $$p\n" unless substr($$t, $$p, 1) eq '"';
            my $k = _string($t, $p);
            _ws($t, $p);
            die "json: expected ':' at $$p\n" unless substr($$t, $$p, 1) eq ':';
            $$p++;
            $h{$k} = _value($t, $p, $depth + 1);
            _ws($t, $p);
            my $d = substr($$t, $$p, 1);
            $$p++;
            next if $d eq ',';
            return \%h if $d eq '}';
            die "json: expected ',' or '}' at " . ($$p - 1) . "\n";
        }
    }
    if ($c eq '[') {
        $$p++;
        my @a;
        _ws($t, $p);
        if (substr($$t, $$p, 1) eq ']') { $$p++; return \@a }
        while (1) {
            push @a, _value($t, $p, $depth + 1);
            _ws($t, $p);
            my $d = substr($$t, $$p, 1);
            $$p++;
            next if $d eq ',';
            return \@a if $d eq ']';
            die "json: expected ',' or ']' at " . ($$p - 1) . "\n";
        }
    }
    return _string($t, $p) if $c eq '"';
    pos($$t) = $$p;
    if ($$t =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/gc) {
        my $n = $1;
        $$p = pos($$t);
        return 0 + $n;
    }
    if ($$t =~ /\Gtrue/gc)  { $$p = pos($$t); return $true }
    if ($$t =~ /\Gfalse/gc) { $$p = pos($$t); return $false }
    if ($$t =~ /\Gnull/gc)  { $$p = pos($$t); return undef }
    die "json: unexpected character at $$p\n";
}

my %UNESC = ('"' => '"', '\\' => '\\', '/' => '/', b => "\x08", f => "\x0c", n => "\n", r => "\r", t => "\t");

sub _string {
    my ($t, $p) = @_;
    $$p++;    # opening quote
    my $out = '';
    pos($$t) = $$p;
    while (1) {
        if ($$t =~ /\G([^"\\\x00-\x1f]+)/gc) { $out .= $1; next }
        if ($$t =~ /\G"/gc) { $$p = pos($$t); utf8::downgrade($out) if $out !~ /[^\x00-\x7f]/; return $out }
        if ($$t =~ /\G\\u([0-9a-fA-F]{4})/gc) {
            my $cp = hex $1;
            if ($cp >= 0xD800 && $cp <= 0xDBFF) {
                if ($$t =~ /\G\\u([dD][c-fC-F][0-9a-fA-F]{2})/gc) {
                    $cp = 0x10000 + (($cp - 0xD800) << 10) + (hex($1) - 0xDC00);
                } else {
                    $cp = 0xFFFD;
                }
            } elsif ($cp >= 0xDC00 && $cp <= 0xDFFF) {
                $cp = 0xFFFD;
            }
            $out .= chr $cp;
            next;
        }
        if ($$t =~ /\G\\(["\\\/bfnrt])/gc) { $out .= $UNESC{$1}; next }
        my $at = pos($$t) // $$p;
        die "json: bad string at $at\n";
    }
}

# ---------------------------------------------------------------- encode

my %ESC = ('"' => '\\"', '\\' => '\\\\', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t', "\x08" => '\\b', "\x0c" => '\\f');

sub _str {
    my ($s) = @_;
    $s =~ s/(["\\\n\r\t\x08\x0c])/$ESC{$1}/g;
    $s =~ s/([\x00-\x1f\x7f\x{2028}\x{2029}])/sprintf('\\u%04x', ord $1)/ge;
    return '"' . $s . '"';
}

sub _is_number {
    my ($v) = @_;
    no warnings 'numeric';
    return 0 if utf8::is_utf8($v);
    return 0 unless length((my $dummy = '') & $v);
    return 0 unless 0 + $v eq $v;
    return 0 unless $v * 0 == 0;
    return 1;
}

sub encode {
    my ($v) = @_;
    return 'null' unless defined $v;
    my $r = ref $v;
    if (!$r) {
        return _is_number($v) ? (0 + $v) . '' : _str("$v");
    }
    return ($$v ? 'true' : 'false') if $r eq 'jsonc::Bool';
    if ($r eq 'jsonc::Obj') {
        my @kv = @$v;
        my @parts;
        for (my $i = 0; $i < @kv; $i += 2) {
            push @parts, _str("$kv[$i]") . ':' . encode($kv[$i + 1]);
        }
        return '{' . join(',', @parts) . '}';
    }
    if ($r eq 'HASH') {
        return '{' . join(',', map { _str($_) . ':' . encode($v->{$_}) } sort keys %$v) . '}';
    }
    if ($r eq 'ARRAY') {
        return '[' . join(',', map { encode($_) } @$v) . ']';
    }
    if ($r eq 'SCALAR') {
        return $$v ? 'true' : 'false';
    }
    return _str("$v");
}

# encode to UTF-8 bytes
sub encode_bytes {
    my $s = encode($_[0]);
    utf8::encode($s);
    return $s;
}

# Pretty form (two-space indent, sorted keys), for files a person reads.
sub encode_pretty {
    my ($v, $ind) = @_;
    $ind //= '';
    my $r = ref $v;
    my $in = $ind . '  ';
    if ($r eq 'HASH' && %$v) {
        return "{\n" . join(",\n", map { $in . _str($_) . ': ' . encode_pretty($v->{$_}, $in) } sort keys %$v) . "\n$ind}";
    }
    if ($r eq 'jsonc::Obj' && @$v) {
        my @kv = @$v;
        my @parts;
        for (my $i = 0; $i < @kv; $i += 2) { push @parts, $in . _str("$kv[$i]") . ': ' . encode_pretty($kv[$i + 1], $in) }
        return "{\n" . join(",\n", @parts) . "\n$ind}";
    }
    if ($r eq 'ARRAY' && @$v) {
        return "[\n" . join(",\n", map { $in . encode_pretty($_, $in) } @$v) . "\n$ind]";
    }
    return encode($v);
}

1;

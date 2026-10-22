package watch::bundle;
# lib/watch/bundle.pm: the `report` zip writer and reader, and HMAC-SHA256 (WATCHER-SPEC
# §8.1 Output, W-BETA B.6). Owner: WP-watch. Floor modules only (R-1, AT-P-11 L1): an own
# zip writer (local headers, central directory, CRC-32 from a 256-entry table). Each entry is
# STORE, or DEFLATE when the optional raw-deflate module loads (inside an eval: W-BETA B.6,
# XR-20; the floor lint allows it since W2C-4) and the deflated body is smaller. An entry whose
# deflated body would be more than $DEFLATE_RATIO_MAX times smaller stays STORE, so a bundle
# never trips the analyzer's ratio-bomb refusal (tools/beta-analyze RATIO_MAX 100). The reader
# takes STORE, and DEFLATE when the raw-inflate module loads; any other method is an error.
# HMAC-SHA256 uses Digest::SHA when present, else the caller's sha256 (the helper's embedded
# one). No encryption, no symlinks, no absolute names, no `..`.
use strict;
use warnings;
use utf8;
use POSIX ();

my @CRC;
for my $n (0 .. 255) {
    my $c = $n;
    for (1 .. 8) { $c = ($c & 1) ? (0xEDB88320 ^ ($c >> 1)) : ($c >> 1) }
    $CRC[$n] = $c;
}

sub crc32 {
    my ($data) = @_;
    my $c = 0xFFFFFFFF;
    $c = $CRC[($c ^ $_) & 0xFF] ^ ($c >> 8) for unpack('C*', $data);
    return ($c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

# undef: probe the optional modules once; 0: STORE only (tests set it); 1: available.
# STORE_TEST_ZIP_STORE=1 (only with STORE_TEST_MODE=1) forces STORE, for the --max-mb case.
our $DEFLATE;
our $INFLATE;
our $DEFLATE_RATIO_MAX = 50;

sub _deflate {
    my ($data) = @_;
    $DEFLATE = 0 if !defined $DEFLATE && ($ENV{STORE_TEST_MODE} // q()) eq q(1) && ($ENV{STORE_TEST_ZIP_STORE} // q()) eq q(1);
    $DEFLATE = (eval { require IO::Compress::RawDeflate; 1 } ? 1 : 0) unless defined $DEFLATE;
    return undef unless $DEFLATE && length $data;
    my $out;
    my $ok = eval { IO::Compress::RawDeflate::rawdeflate(\$data => \$out, -Level => 9) };
    return undef unless $ok && defined $out;
    return undef if length($out) >= length($data) || length($data) > $DEFLATE_RATIO_MAX * length($out);
    return $out;
}

# _inflate(body, size) -> the bytes, or undef (no module, a bad stream, or more than the declared
# size: the reader never inflates past what the header says, so a bomb stops at $size).
sub _inflate {
    my ($body, $size) = @_;
    $INFLATE = (eval { require IO::Uncompress::RawInflate; 1 } ? 1 : 0) unless defined $INFLATE;
    return undef unless $INFLATE;
    my $out = '';
    my $ok = eval {
        my $z = IO::Uncompress::RawInflate->new(\$body, Transparent => 0) or return 0;
        while (1) {
            my $buf;
            my $n = $z->read($buf, 65536);
            return 0 if !defined $n || $n < 0;
            last if $n == 0;
            $out .= $buf;
            return 0 if length($out) > $size;
        }
        $z->close;
        1;
    };
    return $ok ? $out : undef;
}

sub _dos_time {
    my ($t) = @_;
    my @l = localtime($t);
    my $year = $l[5] + 1900;
    $year = 1980 if $year < 1980;
    my $date = (($year - 1980) << 9) | (($l[4] + 1) << 5) | $l[3];
    my $time = ($l[2] << 11) | ($l[1] << 5) | int($l[0] / 2);
    return ($time, $date);
}

# A safe entry name: relative, no `..`, no backslash, no control characters.
sub safe_name {
    my ($n) = @_;
    return 0 unless defined $n && length $n && length($n) <= 200;
    return 0 if $n =~ m{\A/} || $n =~ m{(?:\A|/)\.\.(?:/|\z)} || $n =~ /[\\\x00-\x1f\x7f]/ || $n =~ m{//};
    return 1;
}

# zip([[name, bytes], ...], epoch) -> the archive bytes.
sub zip {
    my ($entries, $now) = @_;
    my ($time, $date) = _dos_time($now // time);
    my ($out, $cd) = ('', '');
    for my $e (@$entries) {
        my ($name, $data) = @$e;
        die "bundle: bad entry name\n" unless safe_name($name);
        utf8::encode($data) if utf8::is_utf8($data);
        my $crc = crc32($data);
        my $d = _deflate($data);
        my ($method, $body) = defined $d ? (8, $d) : (0, $data);
        my $off = length $out;
        $out .= pack('VvvvvvVVVvv', 0x04034b50, 20, 0x0800, $method, $time, $date, $crc,
                     length($body), length($data), length($name), 0) . $name . $body;
        # version made by: 3 (Unix) << 8 | 20; external attributes: a regular file, 0600.
        $cd .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, (3 << 8) | 20, 20, 0x0800, $method, $time, $date, $crc,
                    length($body), length($data), length($name), 0, 0, 0, 0, (0100600 << 16), $off) . $name;
    }
    my $n = scalar @$entries;
    return $out . $cd . pack('VvvvvVVv', 0x06054b50, 0, 0, $n, $n, length($cd), length($out), 0);
}

# unzip(bytes) -> {entries => [{name, data, method, symlink, size, csize}], error}
# Reads the central directory; checks each local header and CRC.
sub unzip {
    my ($z) = @_;
    my $len = length $z;
    my $eocd = rindex($z, pack('V', 0x06054b50));
    return { error => 'no-end-record' } if $eocd < 0 || $len - $eocd < 22;
    my (undef, undef, undef, undef, $n, $cdsize, $cdoff) = unpack('VvvvvVV', substr($z, $eocd, 20));
    return { error => 'bad-directory' } if $cdoff + $cdsize > $len;
    my @e;
    my $p = $cdoff;
    for (1 .. $n) {
        return { error => 'bad-directory' } if $p + 46 > $len || unpack('V', substr($z, $p, 4)) != 0x02014b50;
        my @h = unpack('VvvvvvvVVVvvvvvVV', substr($z, $p, 46));
        my ($made, $flags, $method, $crc, $csize, $size, $nlen, $xlen, $clen, $ext, $loff) = @h[1, 3, 4, 7, 8, 9, 10, 11, 12, 15, 16];
        my $name = substr($z, $p + 46, $nlen);
        $p += 46 + $nlen + $xlen + $clen;
        my $mode = ($ext >> 16) & 0xFFFF;
        my %r = (name => $name, method => $method, size => $size, csize => $csize,
                 symlink => ((($made >> 8) == 3) && (($mode & 0170000) == 0120000)) ? 1 : 0,
                 encrypted => ($flags & 1) ? 1 : 0);
        return { error => 'bad-local-header', entries => \@e } if $loff + 30 > $len || unpack('V', substr($z, $loff, 4)) != 0x04034b50;
        my ($lnlen, $lxlen) = unpack('vv', substr($z, $loff + 26, 4));
        my $body = substr($z, $loff + 30 + $lnlen + $lxlen, $csize);
        if ($method == 0) { $r{data} = $body }
        elsif ($method == 8) { $r{data} = _inflate($body, $size); $r{error} = 'method' unless defined $r{data} }
        else { $r{error} = 'method' }
        $r{error} //= 'size' if defined $r{data} && length($r{data}) != $size;
        $r{error} //= 'crc' if defined $r{data} && crc32($r{data}) != $crc;
        push @e, \%r;
    }
    return { entries => \@e };
}

# HMAC-SHA256 (RFC 2104), hex. $sha256 is sub(bytes) -> hex, used when Digest::SHA is absent.
my $DIGEST;
sub hmac_sha256_hex {
    my ($key, $msg, $sha256) = @_;
    utf8::encode($msg) if utf8::is_utf8($msg);
    $DIGEST = eval { require Digest::SHA; 1 } ? 1 : 0 unless defined $DIGEST;
    return Digest::SHA::hmac_sha256_hex($msg, $key) if $DIGEST;
    die "bundle: no sha256\n" unless ref $sha256 eq 'CODE';
    my $h = sub { return pack('H*', $sha256->($_[0])) };
    $key = $h->($key) if length($key) > 64;
    $key .= "\0" x (64 - length $key);
    my $inner = $h->(($key ^ ("\x36" x 64)) . $msg);
    return unpack('H*', $h->(($key ^ ("\x5c" x 64)) . $inner));
}

1;

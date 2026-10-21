package sha;
# lib/sha.pm: sha256 (ROOT-RULINGS R-1). Owner: WP-core.
# Order: Digest::SHA when it loads; else, for files, `sha256sum` / `shasum -a 256`;
# else the embedded pure-Perl SHA-256 (files up to 8 MiB). Text always has an
# answer (embedded). hex256_file returns undef when no route works ("unavailable").
use strict;
use warnings;

my $HAVE_DIGEST;
sub _digest {
    return $HAVE_DIGEST if defined $HAVE_DIGEST;
    $HAVE_DIGEST = eval { require Digest::SHA; 1 } ? 1 : 0;
    return $HAVE_DIGEST;
}

# hex256(bytes) -> 64 hex chars. Character strings are encoded to UTF-8 first.
sub hex256 {
    my ($data) = @_;
    $data = '' unless defined $data;
    if (utf8::is_utf8($data)) { my $c = $data; utf8::encode($c); $data = $c }
    return Digest::SHA::sha256_hex($data) if _digest();
    return pure_hex256($data);
}

sub hex256_file {
    my ($path) = @_;
    return undef unless defined $path && -f $path && -r _;
    if (_digest()) {
        my $d = eval { Digest::SHA->new(256)->addfile($path, 'b')->hexdigest };
        return $d if $d;
    }
    for my $cmd (['sha256sum', $path], ['shasum', '-a', '256', $path]) {
        my $bin = util::which($cmd->[0]) or next;
        my $r = util::run([$bin, @$cmd[1 .. $#$cmd]], timeout_ms => 20000);
        if ($r->{exit} == 0 && $r->{out} =~ /^([0-9a-f]{64})\b/) { return $1 }
    }
    my $size = -s $path;
    return undef if !defined $size || $size > 8 * 1024 * 1024;
    my $bytes = util::read_file($path);
    return undef unless defined $bytes;
    return pure_hex256($bytes);
}

# ---- embedded SHA-256 (FIPS 180-4), 32-bit words on any perl with 64-bit IV or not
my @K = (
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
);

sub pure_hex256 {
    my ($msg) = @_;
    if (utf8::is_utf8($msg)) { my $c = $msg; utf8::encode($c); $msg = $c }
    use integer;
    my @H = (0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19);
    my $len = length $msg;
    my $bits_hi = ($len >> 29) & 0xffffffff;
    my $bits_lo = ($len << 3) & 0xffffffff;
    $msg .= "\x80";
    $msg .= "\0" x ((120 - (length($msg) % 64)) % 64);
    $msg .= pack('N2', $bits_hi, $bits_lo);
    my $M = 0xffffffff;
    for (my $off = 0; $off < length $msg; $off += 64) {
        my @w = unpack('N16', substr($msg, $off, 64));
        for my $t (16 .. 63) {
            my $x = $w[$t - 15];
            my $s0 = (((($x & $M) >> 7) | ($x << 25)) ^ ((($x & $M) >> 18) | ($x << 14)) ^ (($x & $M) >> 3)) & $M;
            my $y = $w[$t - 2];
            my $s1 = (((($y & $M) >> 17) | ($y << 15)) ^ ((($y & $M) >> 19) | ($y << 13)) ^ (($y & $M) >> 10)) & $M;
            $w[$t] = ($w[$t - 16] + $s0 + $w[$t - 7] + $s1) & $M;
        }
        my ($a, $b, $c, $d, $e, $f, $g, $h) = @H;
        for my $t (0 .. 63) {
            my $S1 = (((($e & $M) >> 6) | ($e << 26)) ^ ((($e & $M) >> 11) | ($e << 21)) ^ ((($e & $M) >> 25) | ($e << 7))) & $M;
            my $ch = (($e & $f) ^ ((~$e) & $g)) & $M;
            my $t1 = ($h + $S1 + $ch + $K[$t] + $w[$t]) & $M;
            my $S0 = (((($a & $M) >> 2) | ($a << 30)) ^ ((($a & $M) >> 13) | ($a << 19)) ^ ((($a & $M) >> 22) | ($a << 10))) & $M;
            my $maj = (($a & $b) ^ ($a & $c) ^ ($b & $c)) & $M;
            my $t2 = ($S0 + $maj) & $M;
            $h = $g; $g = $f; $f = $e;
            $e = ($d + $t1) & $M;
            $d = $c; $c = $b; $b = $a;
            $a = ($t1 + $t2) & $M;
        }
        $H[0] = ($H[0] + $a) & $M; $H[1] = ($H[1] + $b) & $M;
        $H[2] = ($H[2] + $c) & $M; $H[3] = ($H[3] + $d) & $M;
        $H[4] = ($H[4] + $e) & $M; $H[5] = ($H[5] + $f) & $M;
        $H[6] = ($H[6] + $g) & $M; $H[7] = ($H[7] + $h) & $M;
    }
    no integer;
    return join '', map { sprintf '%08x', $_ & 0xffffffff } @H;
}

1;

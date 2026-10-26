# DP-12: watch::io::sha256_hex of a character string with a code point above 0xFF
# (an em dash) died in Digest::SHA ("Wide character"). It hashes the UTF-8 bytes now,
# so a character string and its encoded bytes give the same digest, and a core-supplied
# sha256 sub is handed bytes too.
my %got;
{
    steps => [
        { call => 'code', code => sub {
            my $s = "a\x{2014}b";
            my $b = "a\xe2\x80\x94b";
            $got{wide} = eval { watch::io::sha256_hex($s) };
            $got{wide_err} = $@;
            $got{bytes} = watch::io::sha256_hex($b);
            $got{latin} = watch::io::sha256_hex("caf\xe9");            # byte string, hashed as is
            my $u = "caf\xe9"; utf8::upgrade($u);
            $got{latin_chars} = watch::io::sha256_hex($u);             # same text as characters: UTF-8
            $got{core_arg} = undef;
            my $ctx = { sha256 => sub { $got{core_arg} = $_[0]; return sha::hex256($_[0]) } };
            $got{core} = watch::io::sha256_hex($s, $ctx);
            $got{undef} = watch::io::sha256_hex(undef);
        } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{wide_err}, '', 'a wide character does not die');
        $E->ok(defined $got{wide} && $got{wide} =~ /\A[0-9a-f]{64}\z/, 'a 64-hex digest');
        $E->is($got{wide}, $got{bytes}, 'characters hash as their UTF-8 bytes');
        $E->ok($got{latin} ne $got{latin_chars}, 'a latin-1 byte string is not re-encoded; the same text as characters is');
        $E->is($got{core_arg}, "a\xe2\x80\x94b", "core's sha256 sub is handed UTF-8 bytes");
        $E->is($got{core}, $got{bytes}, "core's digest agrees");
        $E->ok(!defined $got{undef}, 'undef in, undef out');
    },
};

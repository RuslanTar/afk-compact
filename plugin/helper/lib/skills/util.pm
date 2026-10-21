package skills::util;
# lib/skills/util.pm: small shared tools for the skill subcommands (WP-skills).
# Floor modules only (RUNTIME §2.4). Text is handled as bytes throughout:
# files, JSON strings and spec regexes are all UTF-8 byte strings.
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_APPEND O_RDONLY LOCK_EX LOCK_UN);
use POSIX ();
use Errno ();
use File::Basename ();
use Cwd ();

# ---------------------------------------------------------------- JSON codec

sub json_encode {
    my ($v) = @_;
    my $r = ref $v;
    if (!defined $v) { return 'null' }
    if ($r eq 'HASH') {
        return '{' . join(',', map { _jstr($_) . ':' . json_encode($v->{$_}) } sort keys %$v) . '}';
    }
    if ($r eq 'ARRAY') { return '[' . join(',', map { json_encode($_) } @$v) . ']' }
    if ($r eq 'SCALAR') { return $$v ? 'true' : 'false' }
    if ($r) { return _jstr("$v") }
    if (_is_num($v)) { return "$v" }
    return _jstr($v);
}

sub _is_num {
    my ($v) = @_;
    return 0 unless $v =~ /\A-?(?:0|[1-9][0-9]{0,15})(?:\.[0-9]+)?\z/;
    no warnings;
    return (($v ^ $v) eq '0') ? 1 : 0;
}

sub _jstr {
    my ($s) = @_;
    $s =~ s/(["\\])/\\$1/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f\x7f])/sprintf('\\u%04x', ord $1)/ge;
    return '"' . $s . '"';
}

sub json_true  { return \1 }
sub json_false { return \0 }

# Decode one JSON text. Returns the value; dies "json: ..." on bad input.
# true/false decode to 1/0, null to undef; \u escapes become UTF-8 bytes.
sub json_decode {
    my ($text) = @_;
    die "json: empty\n" unless defined $text;
    my $pos = 0;
    my $v = _jval(\$text, \$pos);
    _jws(\$text, \$pos);
    die "json: trailing data at $pos\n" if $pos < length $text;
    return $v;
}

sub _jws { my ($t, $p) = @_; pos($$t) = $$p; $$t =~ /\G[ \t\r\n]*/gc; $$p = pos($$t) }

sub _jval {
    my ($t, $p) = @_;
    _jws($t, $p);
    my $c = substr($$t, $$p, 1);
    die "json: unexpected end\n" if $c eq '';
    if ($c eq '{') {
        $$p++;
        my %h;
        _jws($t, $p);
        if (substr($$t, $$p, 1) eq '}') { $$p++; return \%h }
        while (1) {
            _jws($t, $p);
            die "json: key expected at $$p\n" unless substr($$t, $$p, 1) eq '"';
            my $k = _jstring($t, $p);
            _jws($t, $p);
            die "json: colon expected at $$p\n" unless substr($$t, $$p, 1) eq ':';
            $$p++;
            $h{$k} = _jval($t, $p);
            _jws($t, $p);
            my $d = substr($$t, $$p, 1);
            $$p++;
            last if $d eq '}';
            die "json: comma expected at $$p\n" unless $d eq ',';
        }
        return \%h;
    }
    if ($c eq '[') {
        $$p++;
        my @a;
        _jws($t, $p);
        if (substr($$t, $$p, 1) eq ']') { $$p++; return \@a }
        while (1) {
            push @a, _jval($t, $p);
            _jws($t, $p);
            my $d = substr($$t, $$p, 1);
            $$p++;
            last if $d eq ']';
            die "json: comma expected at $$p\n" unless $d eq ',';
        }
        return \@a;
    }
    if ($c eq '"') { return _jstring($t, $p) }
    pos($$t) = $$p;
    if ($$t =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/gc) {
        $$p = pos($$t);
        return 0 + $1;
    }
    if ($$t =~ /\Gtrue/gc)  { $$p = pos($$t); return 1 }
    if ($$t =~ /\Gfalse/gc) { $$p = pos($$t); return 0 }
    if ($$t =~ /\Gnull/gc)  { $$p = pos($$t); return undef }
    die "json: bad value at $$p\n";
}

my %ESC = ('"' => '"', '\\' => '\\', '/' => '/', b => "\b", f => "\f", n => "\n", r => "\r", t => "\t");

sub _jstring {
    my ($t, $p) = @_;
    $$p++;
    my $out = '';
    while (1) {
        pos($$t) = $$p;
        if ($$t =~ /\G([^"\\]+)/gc) { $out .= $1; $$p = pos($$t); next }
        my $c = substr($$t, $$p, 1);
        die "json: unterminated string\n" if $c eq '';
        if ($c eq '"') { $$p++; return $out }
        my $e = substr($$t, $$p + 1, 1);
        if (exists $ESC{$e}) { $out .= $ESC{$e}; $$p += 2; next }
        if ($e eq 'u') {
            my $hex = substr($$t, $$p + 2, 4);
            die "json: bad \\u escape\n" unless $hex =~ /\A[0-9a-fA-F]{4}\z/;
            my $cp = hex $hex;
            $$p += 6;
            if ($cp >= 0xD800 && $cp <= 0xDBFF && substr($$t, $$p, 2) eq '\\u') {
                my $lo = hex substr($$t, $$p + 2, 4);
                if ($lo >= 0xDC00 && $lo <= 0xDFFF) {
                    $cp = 0x10000 + (($cp - 0xD800) << 10) + ($lo - 0xDC00);
                    $$p += 6;
                }
            }
            $out .= _utf8($cp);
            next;
        }
        die "json: bad escape\n";
    }
}

sub _utf8 {
    my ($cp) = @_;
    return chr($cp) if $cp < 0x80;
    return chr(0xC0 | ($cp >> 6)) . chr(0x80 | ($cp & 0x3F)) if $cp < 0x800;
    return chr(0xE0 | ($cp >> 12)) . chr(0x80 | (($cp >> 6) & 0x3F)) . chr(0x80 | ($cp & 0x3F)) if $cp < 0x10000;
    return chr(0xF0 | ($cp >> 18)) . chr(0x80 | (($cp >> 12) & 0x3F))
         . chr(0x80 | (($cp >> 6) & 0x3F)) . chr(0x80 | ($cp & 0x3F));
}

# ---------------------------------------------------------------- sha256

my $HAVE_DIGEST;
sub sha256_hex {
    my ($data) = @_;
    if (!defined $HAVE_DIGEST) {
        $HAVE_DIGEST = eval { require Digest::SHA; 1 } ? 1 : 0;
    }
    return Digest::SHA::sha256_hex($data) if $HAVE_DIGEST;
    return _sha256_pp($data);
}

sub sha256_file {
    my ($path) = @_;
    my $d = read_file($path);
    return undef unless defined $d;
    return sha256_hex($d);
}

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

sub _sha256_pp {
    my ($msg) = @_;
    my $M = 0xffffffff;
    my @h = (0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19);
    my $len = length($msg) * 8;
    $msg .= "\x80";
    $msg .= "\x00" while (length($msg) % 64) != 56;
    $msg .= pack('NN', int($len / 4294967296), $len % 4294967296);
    my $rotr = sub { my ($x, $n) = @_; return (($x >> $n) | ($x << (32 - $n))) & $M };
    for (my $off = 0; $off < length $msg; $off += 64) {
        my @w = unpack('N16', substr($msg, $off, 64));
        for my $i (16 .. 63) {
            my $s0 = $rotr->($w[$i - 15], 7) ^ $rotr->($w[$i - 15], 18) ^ ($w[$i - 15] >> 3);
            my $s1 = $rotr->($w[$i - 2], 17) ^ $rotr->($w[$i - 2], 19) ^ ($w[$i - 2] >> 10);
            $w[$i] = ($w[$i - 16] + $s0 + $w[$i - 7] + $s1) & $M;
        }
        my ($a, $b, $c, $d, $e, $f, $g, $hh) = @h;
        for my $i (0 .. 63) {
            my $S1 = $rotr->($e, 6) ^ $rotr->($e, 11) ^ $rotr->($e, 25);
            my $ch = ($e & $f) ^ ((~$e & $M) & $g);
            my $t1 = ($hh + $S1 + $ch + $K[$i] + $w[$i]) & $M;
            my $S0 = $rotr->($a, 2) ^ $rotr->($a, 13) ^ $rotr->($a, 22);
            my $mj = ($a & $b) ^ ($a & $c) ^ ($b & $c);
            my $t2 = ($S0 + $mj) & $M;
            ($hh, $g, $f, $e, $d, $c, $b, $a) = ($g, $f, $e, ($d + $t1) & $M, $c, $b, $a, ($t1 + $t2) & $M);
        }
        my @v = ($a, $b, $c, $d, $e, $f, $g, $hh);
        $h[$_] = ($h[$_] + $v[$_]) & $M for 0 .. 7;
    }
    return join '', map { sprintf '%08x', $_ } @h;
}

# ---------------------------------------------------------------- clock

sub test_mode { return (($ENV{STORE_TEST_MODE} // '') eq '1') ? 1 : 0 }

sub now {
    if (test_mode() && defined $ENV{STORE_TEST_NOW} && $ENV{STORE_TEST_NOW} ne '') {
        my $e = iso_to_epoch($ENV{STORE_TEST_NOW});
        return $e if defined $e;
    }
    return time;
}

sub timegm {
    my ($s, $mi, $h, $d, $mo, $y) = @_;    # $mo 0-11, $y full year
    my @cum = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334);
    my $leap = ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0)) ? 1 : 0;
    my $days = ($y - 1970) * 365
        + int(($y - 1969) / 4) - int(($y - 1901) / 100) + int(($y - 1601) / 400)
        + $cum[$mo] + ($mo > 1 ? $leap : 0) + $d - 1;
    return $days * 86400 + $h * 3600 + $mi * 60 + $s;
}

sub iso_to_epoch {
    my ($iso) = @_;
    return undef unless defined $iso;
    return undef unless $iso =~ /\A(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?\s*(Z|[+-]\d\d:?\d\d)?\z/;
    my $e = timegm($6 // 0, $5, $4, $3, $2 - 1, $1);
    my $tz = $7;
    if (!defined $tz) {
        return $e - utc_offset($e);
    }
    return $e if $tz eq 'Z';
    my ($sg, $oh, $om) = $tz =~ /([+-])(\d\d):?(\d\d)/;
    my $off = ($oh * 3600 + $om * 60) * ($sg eq '-' ? -1 : 1);
    return $e - $off;
}

sub utc_offset {
    my ($e) = @_;
    my @l = localtime $e;
    return timegm(@l[0 .. 3], $l[4], $l[5] + 1900) - $e;
}

sub iso_local {
    my ($e) = @_;
    $e //= now();
    my $off = utc_offset($e);
    my $sg = $off < 0 ? '-' : '+';
    my $a = abs $off;
    return POSIX::strftime('%Y-%m-%dT%H:%M:%S', localtime $e) . sprintf('%s%02d:%02d', $sg, int($a / 3600), int(($a % 3600) / 60));
}

sub hhmm      { return POSIX::strftime('%H:%M', localtime($_[0] // now())) }
sub mmdd_hhmm { return POSIX::strftime('%m-%d %H:%M', localtime($_[0] // now())) }
sub ymd       { return POSIX::strftime('%Y-%m-%d', localtime($_[0] // now())) }
sub stem_time { return POSIX::strftime('%Y-%m-%d_%H-%M-%S', localtime($_[0] // now())) }

# ---------------------------------------------------------------- files

sub read_file {
    my ($path, $max) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my $data = '';
    if (defined $max) {
        read($fh, $data, $max);
    } else {
        local $/;
        $data = <$fh>;
        $data = '' unless defined $data;
    }
    close $fh;
    return $data;
}

sub mkdir_p {
    my ($dir) = @_;
    return 1 if -d $dir;
    my $parent = File::Basename::dirname($dir);
    mkdir_p($parent) if $parent ne $dir && !-d $parent;
    if (!mkdir($dir, 0700)) {
        return 1 if -d $dir;
        die "mkdir $dir: $!\n";
    }
    chmod 0700, $dir;
    return 1;
}

# Exclusive create. Returns 1 when written, 0 when the file already exists.
sub write_excl {
    my ($path, $content, $mode) = @_;
    $mode //= 0600;
    my $fh;
    if (!sysopen($fh, $path, O_WRONLY | O_CREAT | O_EXCL, $mode)) {
        return 0 if $!{EEXIST};
        die "create $path: $!\n";
    }
    binmode $fh;
    _write_all($fh, $content, $path);
    close($fh) or die "close $path: $!\n";
    chmod $mode, $path;
    return 1;
}

# Whole-file replace through a temp file and rename (own files only).
sub write_replace {
    my ($path, $content, $mode) = @_;
    $mode //= 0600;
    my $tmp = $path . '.tmp-' . $$ . '-' . int(rand(1e6));
    write_excl($tmp, $content, $mode) or die "tmp exists: $tmp\n";
    rename($tmp, $path) or die "rename $path: $!\n";
    return 1;
}

# One append under flock where the file system allows it (R-4).
sub append_line {
    my ($path, $line) = @_;
    my $fh;
    sysopen($fh, $path, O_WRONLY | O_CREAT | O_APPEND, 0600) or die "append $path: $!\n";
    binmode $fh;
    my $locked = flock($fh, LOCK_EX);
    _write_all($fh, $line, $path);
    flock($fh, LOCK_UN) if $locked;
    close $fh;
    return 1;
}

sub _write_all {
    my ($fh, $content, $path) = @_;
    my $off = 0;
    my $len = length $content;
    while ($off < $len) {
        my $n = syswrite($fh, $content, $len - $off, $off);
        die "write $path: $!\n" unless defined $n;
        $off += $n;
    }
}

# Plain byte copy by exclusive create (no File::Copy on the floor).
sub copy_file {
    my ($src, $dst, $mode) = @_;
    $mode //= 0600;
    my $in;
    sysopen($in, $src, O_RDONLY) or return 'missing';
    binmode $in;
    my $out;
    if (!sysopen($out, $dst, O_WRONLY | O_CREAT | O_EXCL, $mode)) {
        close $in;
        return 'exists' if $!{EEXIST};
        die "create $dst: $!\n";
    }
    binmode $out;
    my $buf;
    while (1) {
        my $n = sysread($in, $buf, 65536);
        die "read $src: $!\n" unless defined $n;
        last if $n == 0;
        _write_all($out, $buf, $dst);
    }
    close $in;
    close($out) or die "close $dst: $!\n";
    chmod $mode, $dst;
    return 'copied';
}

# Exclusive create with -2, -3 … on a clash. Returns the path written.
sub unique_path {
    my ($dir, $base, $ext) = @_;
    $ext //= '';
    for my $n (1 .. 99) {
        my $p = $dir . '/' . $base . ($n == 1 ? '' : "-$n") . $ext;
        return $p unless -e $p;
    }
    die "no free name for $base\n";
}

sub list_dir {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return ();
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    return sort @e;
}

sub expand_tilde {
    my ($p) = @_;
    return $p unless defined $p;
    my $home = $ENV{HOME} // '';
    $p =~ s/\A~(?=\/|\z)/$home/;
    return $p;
}

sub abbrev_home {
    my ($p) = @_;
    my $home = $ENV{HOME} // '';
    return $p if $home eq '' || !defined $p;
    $p =~ s/\A\Q$home\E(?=\/|\z)/~/;
    return $p;
}

sub abs_path {
    my ($p) = @_;
    return undef unless defined $p && $p ne '';
    $p = expand_tilde($p);
    $p = Cwd::getcwd() . '/' . $p unless $p =~ m{\A/};
    my $r = Cwd::abs_path($p);
    return defined $r ? $r : $p;
}

# A setting or flag value that counts as unset (MOD §2.6, HDN §6).
sub unset_value {
    my ($v) = @_;
    return 1 if !defined $v || $v eq '';
    return 1 if $v =~ /\A\$\{/;    # ${user_config.…} or ${CLAUDE_SESSION_ID} left unsubstituted
    return 0;
}

# ---------------------------------------------------------------- processes

# Run argv with a deadline. Returns {rc, out, timed_out}. stderr is discarded.
sub run {
    my ($argv, $timeout_ms, %o) = @_;
    trace($o{trace}) if $o{trace};
    pipe(my $r, my $w) or return { rc => -1, out => '', timed_out => 0 };
    my $pid = fork;
    if (!defined $pid) { return { rc => -1, out => '', timed_out => 0 } }
    if ($pid == 0) {
        close $r;
        open(STDOUT, '>&', $w) or POSIX::_exit(127);
        open(STDERR, '>', '/dev/null');
        open(STDIN, '<', '/dev/null');
        if (defined $o{cwd}) { chdir $o{cwd} or POSIX::_exit(127) }
        { no warnings 'exec'; exec { $argv->[0] } @$argv; }
        POSIX::_exit(127);
    }
    close $w;
    my $out = '';
    my $deadline = time + ($timeout_ms // 2000) / 1000;
    my $timed_out = 0;
    my $rin = '';
    vec($rin, fileno($r), 1) = 1;
    my $max = $o{max_bytes} // 4 * 1024 * 1024;
    while (1) {
        my $left = $deadline - time;
        if ($left <= 0) { $timed_out = 1; last }
        my $n = select(my $rout = $rin, undef, undef, $left > 0.25 ? 0.25 : $left);
        next if $n == 0 || ($n < 0 && $!{EINTR});
        my $got = sysread($r, my $buf, 65536);
        last unless $got;
        $out .= $buf if length($out) < $max;
    }
    close $r;
    if ($timed_out) {
        kill 'TERM', $pid;
        select(undef, undef, undef, 0.1);
        kill 'KILL', $pid;
    }
    waitpid($pid, 0);
    my $rc = $timed_out ? -1 : ($? >> 8);
    return { rc => $rc, out => $out, timed_out => $timed_out };
}

sub trace {
    my ($step) = @_;
    return unless test_mode() && defined $ENV{STORE_TEST_TRACE} && $ENV{STORE_TEST_TRACE} ne '';
    eval { append_line($ENV{STORE_TEST_TRACE}, "$step\n") };
}

sub which {
    my ($name) = @_;
    for my $d (split /:/, ($ENV{PATH} // '')) {
        next if $d eq '';
        return "$d/$name" if -x "$d/$name" && !-d "$d/$name";
    }
    return undef;
}

sub rand_hex {
    my ($n) = @_;
    my $s = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, my $b, $n);
        close $fh;
        $s = unpack('H*', $b) if defined $b && length($b) == $n;
    }
    $s = join '', map { sprintf '%02x', int(rand(256)) } 1 .. $n if $s eq '';
    return $s;
}

1;

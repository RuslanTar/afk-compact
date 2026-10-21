package watch::io;
# lib/watch/io.pm: files, time and hashes for the watcher (floor modules only).
# Owner: WP-watch. Row appends follow BUILD-PLAN §3.1/§3.2 and ROOT-RULINGS R-4:
# one O_APPEND write of <= 4 KB under flock(LOCK_EX), umask 077, 0700 dirs,
# 0600 files. Core may inject its own appender through ctx (lib/watch/ctx.pm).
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_APPEND O_CREAT O_EXCL O_RDONLY O_RDWR LOCK_EX LOCK_NB LOCK_UN SEEK_SET);
use POSIX ();
use watch::json;

our $MAX_ROW = 4096;

my $HIRES;
BEGIN { $HIRES = eval { require Time::HiRes; 1 } ? 1 : 0 }

# --- time -------------------------------------------------------------------

# Epoch seconds (fractional when Time::HiRes loads). STORE_TEST_NOW is honoured
# only with STORE_TEST_MODE=1 (BUILD-PLAN §3.1 test mode).
sub now {
    if (($ENV{STORE_TEST_MODE} || '') eq '1' && defined $ENV{STORE_TEST_NOW} && $ENV{STORE_TEST_NOW} ne '') {
        my $t = parse_iso($ENV{STORE_TEST_NOW});
        return $t if defined $t;
    }
    return $HIRES ? Time::HiRes::time() : time();
}

# Wall clock for budgets; never the test clock.
sub mono { return $HIRES ? Time::HiRes::time() : time() }

sub _days_from_civil {
    my ($y, $m, $d) = @_;
    $y -= $m <= 2 ? 1 : 0;
    my $era = int(($y >= 0 ? $y : $y - 399) / 400);
    my $yoe = $y - $era * 400;
    my $doy = int((153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5) + $d - 1;
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;
    return $era * 146097 + $doe - 719468;
}

sub timegm {
    my ($sec, $min, $hour, $mday, $mon0, $year) = @_;
    return _days_from_civil($year, $mon0 + 1, $mday) * 86400 + $hour * 3600 + $min * 60 + $sec;
}

# ISO 8601 with Z or an offset (fraction optional) -> epoch seconds, or undef.
sub parse_iso {
    my ($s) = @_;
    return undef unless defined $s && !ref $s;
    return undef unless $s =~ /\A(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:?\d\d)?\z/;
    my $t = _days_from_civil($1, $2, $3) * 86400 + $4 * 3600 + $5 * 60 + $6;
    $t += $7 if defined $7;
    my $z = $8;
    if (defined $z && $z ne 'Z') {
        my ($sign, $hh, $mm) = $z =~ /([+-])(\d\d):?(\d\d)/;
        my $off = $hh * 3600 + $mm * 60;
        $t -= $sign eq '+' ? $off : -$off;
    } elsif (!defined $z) {
        $t -= _local_offset(int $t);
    }
    return $t;
}

sub _local_offset {
    my ($t) = @_;
    my @l = localtime($t);
    return timegm(@l[0 .. 4], $l[5] + 1900) - $t;
}

# Local time with offset and milliseconds (WATCH §6.2 envelope `ts`).
sub iso {
    my ($t) = @_;
    $t = now() unless defined $t;
    my $sec = int $t;
    my $ms = int(($t - $sec) * 1000 + 0.5);
    if ($ms >= 1000) { $sec += 1; $ms -= 1000 }
    my @l = localtime($sec);
    my $off = _local_offset($sec);
    my $sign = $off < 0 ? '-' : '+';
    $off = abs $off;
    return POSIX::strftime('%Y-%m-%dT%H:%M:%S', @l) . sprintf('.%03d%s%02d:%02d', $ms, $sign, int($off / 3600), int(($off % 3600) / 60));
}

sub local_date {
    my ($t) = @_;
    return POSIX::strftime('%Y-%m-%d', localtime(int(defined $t ? $t : now())));
}

# --- hashes -----------------------------------------------------------------

# FNV-1a 32 bit as 8 hex: a stable, non-secret id for alert ids and dedupe keys.
sub fnv8 {
    my ($s) = @_;
    my $h = 0x811c9dc5;
    for my $c (unpack 'C*', $s) {
        $h ^= $c;
        $h = ($h * 0x01000193) & 0xffffffff;
    }
    return sprintf '%08x', $h;
}

my $SHA;
BEGIN { $SHA = eval { require Digest::SHA; 1 } ? 1 : 0 }

# sha256 hex of bytes: ctx-supplied function (core's, with its embedded
# fallback) first, then Digest::SHA; undef when neither exists.
sub sha256_hex {
    my ($bytes, $ctx) = @_;
    if ($ctx && ref $ctx->{sha256} eq 'CODE') {
        my $h = eval { $ctx->{sha256}->($bytes) };
        return lc $h if defined $h && $h =~ /\A[0-9a-fA-F]{64}\z/;
    }
    return Digest::SHA::sha256_hex($bytes) if $SHA;
    return undef;
}

# --- files ------------------------------------------------------------------

sub mkdir_p {
    my ($dir) = @_;
    return 1 if -d $dir;
    my $parent = $dir;
    $parent =~ s{/+[^/]+/*\z}{};
    mkdir_p($parent) if length $parent && $parent ne $dir && !-d $parent;
    my $old = umask 077;
    my $ok = mkdir($dir, 0700) || -d $dir;
    umask $old;
    return $ok;
}

sub dirname_of {
    my ($p) = @_;
    (my $d = $p) =~ s{/+[^/]*\z}{};
    return length $d ? $d : '/';
}

# Append one row (a hash) as one line. Returns 1, or dies with a class.
sub append_row {
    my ($path, $row) = @_;
    my $line = watch::json::encode($row) . "\n";
    die "row-too-large\n" if length($line) > $MAX_ROW;
    mkdir_p(dirname_of($path)) or die "mkdir\n";
    my $old = umask 077;
    my $ok = sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT, 0600);
    umask $old;
    die "open\n" unless $ok;
    my $locked = flock($fh, LOCK_EX);
    my $n = syswrite($fh, $line);
    flock($fh, LOCK_UN) if $locked;
    close $fh;
    die "write\n" unless defined $n && $n == length $line;
    return 1;
}

# Exclusive create; returns 1 when created, 0 when it already existed.
sub excl_create {
    my ($path, $content) = @_;
    mkdir_p(dirname_of($path)) or die "mkdir\n";
    my $old = umask 077;
    my $ok = sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    umask $old;
    return 0 unless $ok;
    syswrite($fh, $content) if defined $content && length $content;
    close $fh;
    return 1;
}

# Whole-file write: a temp file beside the target (exclusive create, 0600),
# then rename over it. Returns 1, or 0 with the target untouched.
sub write_atomic {
    my ($path, $content) = @_;
    mkdir_p(dirname_of($path)) or return 0;
    my $tmp = sprintf('%s.tmp-%d-%04x', $path, $$, int(rand(0x10000)));
    my $old = umask 077;
    my $ok = sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600);
    umask $old;
    return 0 unless $ok;
    my $n = syswrite($fh, $content);
    my $closed = close $fh;
    if (defined $n && $n == length($content) && $closed && rename($tmp, $path)) { return 1 }
    unlink $tmp;
    return 0;
}

sub slurp {
    my ($path, $max) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $data;
    if (defined $max) {
        read($fh, $data, $max);
    } else {
        $data = <$fh>;
    }
    close $fh;
    return defined $data ? $data : '';
}

sub read_json_file {
    my ($path) = @_;
    my $d = slurp($path, 1 << 20);
    return undef unless defined $d && length $d;
    my $v = eval { watch::json::decode($d) };
    return $v;
}

# Read a JSONL file; returns [rows] (bad lines skipped, counted in $$bad).
# With `$want` (a regex), a line that does not match is skipped before the
# JSON decode (e.g. qr/"ev"\s*:\s*"copy"/ to decode only the copy rows).
sub read_jsonl {
    my ($path, $bad, $want) = @_;
    my @rows;
    open(my $fh, '<:raw', $path) or return \@rows;
    while (my $line = <$fh>) {
        next unless $line =~ /\S/;
        next if $want && $line !~ $want;
        my $v = eval { watch::json::decode($line) };
        if (ref $v eq 'HASH') { push @rows, $v } elsif ($bad) { $$bad++ }
    }
    close $fh;
    return \@rows;
}

sub list_dir {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return ();
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    return sort @e;
}

# Lock-held whole-file state (the sweeper offsets): open O_RDWR|O_CREAT and
# take a non-blocking exclusive lock. Returns the handle, or undef when busy.
sub open_locked {
    my ($path) = @_;
    mkdir_p(dirname_of($path)) or return undef;
    my $old = umask 077;
    my $ok = sysopen(my $fh, $path, O_RDWR | O_CREAT, 0600);
    umask $old;
    return undef unless $ok;
    unless (flock($fh, LOCK_EX | LOCK_NB)) {
        close $fh;
        return (undef, 'busy');
    }
    binmode $fh;
    return $fh;
}

sub read_handle {
    my ($fh) = @_;
    sysseek($fh, 0, SEEK_SET);
    my ($buf, $data) = ('', '');
    while (sysread($fh, $buf, 65536)) { $data .= $buf }
    return $data;
}

sub rewrite_handle {
    my ($fh, $content) = @_;
    sysseek($fh, 0, SEEK_SET);
    truncate($fh, 0);
    my $n = syswrite($fh, $content);
    return defined $n && $n == length $content;
}

1;

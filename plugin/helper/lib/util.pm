package util;
# lib/util.pm: shared low-level helpers (time, files, processes). Owner: WP-core.
# Floor modules only (RUNTIME §2.4): no File::Copy, File::Find, Time::Local,
# Sys::Hostname; Time::HiRes only when it loads.
use strict;
use warnings;
use utf8;
use Fcntl qw(O_WRONLY O_RDONLY O_RDWR O_CREAT O_EXCL O_APPEND O_TRUNC LOCK_EX LOCK_NB LOCK_UN SEEK_SET);
use POSIX ();
use Errno ();

my $HIRES;
sub _hires {
    return $HIRES if defined $HIRES;
    $HIRES = eval { require Time::HiRes; 1 } ? 1 : 0;
    return $HIRES;
}

sub test_mode { return (($ENV{STORE_TEST_MODE} // '') eq '1') ? 1 : 0 }

# os() -> $^O; in test mode STORE_TEST_OS (msys, cygwin, linux, ...) stands in for it, so the
# MSYS and Cygwin branches (Git Bash's perl: root_form, identity's /proc start time) run on
# any host in the helper cases.
sub os {
    return $ENV{STORE_TEST_OS} if test_mode() && defined $ENV{STORE_TEST_OS} && $ENV{STORE_TEST_OS} =~ /\A[a-z0-9]+\z/;
    return $^O;
}

# stamp_ms() -> 1 when a record stamp may carry milliseconds (Time::HiRes loads). In test mode
# STORE_TEST_NO_HIRES=1 answers 0, so a case can write the stamp a perl without Time::HiRes
# writes on any machine (review of bcdaca6: the start-record tests must not depend on it).
sub stamp_ms {
    return 0 if test_mode() && ($ENV{STORE_TEST_NO_HIRES} // '') eq '1';
    return _hires();
}

# Wall clock as epoch seconds (fractional when Time::HiRes loads).
# STORE_TEST_NOW fixes it in test mode.
sub now {
    if (test_mode() && defined $ENV{STORE_TEST_NOW} && $ENV{STORE_TEST_NOW} ne '') {
        my $t = parse_iso($ENV{STORE_TEST_NOW});
        return $t if defined $t;
    }
    return _hires() ? Time::HiRes::time() : time();
}

# Monotonic-ish elapsed milliseconds for budgets (never the test clock).
sub clock_ms { return int((_hires() ? Time::HiRes::time() : time()) * 1000) }

sub sleep_ms {
    my ($ms) = @_;
    if (_hires()) { Time::HiRes::sleep($ms / 1000) } else { select(undef, undef, undef, $ms / 1000) }
}

sub _offset {
    my ($epoch) = @_;
    my $z = POSIX::strftime('%z', localtime($epoch));
    return 'Z' unless $z =~ /^([+-])(\d\d)(\d\d)$/;
    return "$1$2:$3";
}

# ISO 8601 local time with offset; with $ms true adds .mmm
sub iso {
    my ($epoch, $ms) = @_;
    $epoch = now() unless defined $epoch;
    my $s = int($epoch);
    my $out = POSIX::strftime('%Y-%m-%dT%H:%M:%S', localtime($s));
    $out .= sprintf('.%03d', int(($epoch - $s) * 1000 + 0.0005)) if $ms;
    return $out . _offset($s);
}

sub iso_ms { return iso($_[0], 1) }

# file_stamp(epoch) -> 2026-10-21_14-05-12, the time part of copy and evidence file names
sub file_stamp {
    my ($epoch) = @_;
    $epoch = now() unless defined $epoch;
    return POSIX::strftime('%Y-%m-%d_%H-%M-%S', localtime(int $epoch));
}

# stamp(epoch) -> 2026-10-21 14:05 +0300 (RV-24, small-rulings §3a): local date, time and
# numeric UTC offset, always all three; the offset is the one of that instant (DST). The
# same text `date '+%Y-%m-%d %H:%M %z'` prints, and the spec's `time_re` matches it.
sub stamp {
    my ($epoch) = @_;
    my @lt = localtime(int($epoch // now()));
    return POSIX::strftime('%Y-%m-%d %H:%M', @lt) . ' ' . POSIX::strftime('%z', @lt);
}

sub day {
    my ($epoch) = @_;
    $epoch = now() unless defined $epoch;
    return POSIX::strftime('%Y-%m-%d', localtime(int $epoch));
}

# hhmm(epoch) -> 14:05, for logs that need only the time; text the model reads uses stamp()
sub hhmm {
    my ($epoch) = @_;
    return POSIX::strftime('%H:%M', localtime(int($epoch // now())));
}

sub _days_from_civil {
    my ($y, $m, $d) = @_;
    $y -= $m <= 2 ? 1 : 0;
    my $era = int(($y >= 0 ? $y : $y - 399) / 400);
    my $yoe = $y - $era * 400;
    my $doy = int((153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5) + $d - 1;
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;
    return $era * 146097 + $doe - 719468;
}

# Own timegm (Time::Local is off the floor).
sub timegm {
    my ($sec, $min, $hour, $d, $m, $y) = @_;    # $m 1..12, $y full year
    return _days_from_civil($y, $m, $d) * 86400 + $hour * 3600 + $min * 60 + $sec;
}

# "2026-10-21T14:05:12+03:00", "...12.345Z", "...12" (local) -> epoch
sub parse_iso {
    my ($s) = @_;
    return undef unless defined $s;
    return undef unless $s =~ /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:?\d\d)?$/;
    my ($y, $mo, $d, $h, $mi, $se, $frac, $tz) = ($1, $2, $3, $4, $5, $6, $7, $8);
    my $t = timegm($se, $mi, $h, $d, $mo, $y);
    if (!defined $tz) {
        my $local = POSIX::mktime($se, $mi, $h, $d, $mo - 1, $y - 1900, 0, 0, -1);
        return defined $local ? $local + ($frac ? 0 + $frac : 0) : undef;
    }
    if ($tz ne 'Z') {
        my ($sign, $hh, $mm) = $tz =~ /^([+-])(\d\d):?(\d\d)$/;
        my $off = $hh * 3600 + $mm * 60;
        $t -= $sign eq '+' ? $off : -$off;
    }
    return $t + ($frac ? 0 + $frac : 0);
}

# ---------------------------------------------------------------- paths

sub home { return $ENV{HOME} // (getpwuid($<))[7] // '' }

sub expand_tilde {
    my ($p) = @_;
    return $p unless defined $p;
    my $h = home();
    return $h if $p eq '~';
    $p =~ s{^~/}{$h/};
    return $p;
}

sub abbrev {
    my ($p) = @_;
    return $p unless defined $p;
    $p = text($p);    # display text: a byte path is decoded where it joins text (A4 (3))
    my $h = text(home());
    return $p if $h eq '' || $h eq '/';
    return '~' if $p eq $h;
    $p =~ s{^\Q$h\E/}{~/};
    return $p;
}

sub dirname {
    my ($p) = @_;
    return '.' unless defined $p && $p =~ m{/};
    (my $d = $p) =~ s{/+[^/]*$}{};
    return $d eq '' ? '/' : $d;
}

sub basename {
    my ($p) = @_;
    return '' unless defined $p;
    (my $b = $p) =~ s{/+$}{};
    $b =~ s{^.*/}{};
    return $b;
}

# root_form(raw) -> a store root as configured (handoff_root, log_dir, disposable_root) as an
# absolute path in this platform's form, or undef when it has none (RF-2): ~ is expanded first;
# a path that starts with / is taken as it is; under MSYS or Cygwin perl a drive form (C:/x or
# C:\x) is read through Cygwin::win_to_posix_path when perl has it. Anything else (a relative
# path, a rooted \x, a drive-relative C:x, a drive form on macOS or Linux) is undef and is never
# joined to the cwd: clean_path made <cwd>/C:/x of a drive path, found no work tree there and let
# a sweep write into a root inside a git work tree. The caller refuses it as root-invalid.
sub root_form {
    my ($p) = @_;
    return undef unless defined $p && !ref $p && $p ne '';
    $p = expand_tilde($p);
    return $p if $p =~ m{\A/};
    my $os = os();
    return undef unless ($os eq 'msys' || $os eq 'cygwin') && $p =~ m{\A[A-Za-z]:[/\\]};
    my $f = _win_to_posix() // return undef;
    my $q = eval { $f->($p, 1) };
    return defined $q && $q =~ m{\A/} ? $q : undef;
}

# Cygwin::win_to_posix_path (MSYS and Cygwin perl), or undef. In test mode STORE_TEST_CYGDRIVE=<dir>
# stands in for it: C:\a\b reads as <dir>/c/a/b (MSYS's /c/a/b under a test folder).
sub _win_to_posix {
    if (test_mode() && defined $ENV{STORE_TEST_CYGDRIVE} && $ENV{STORE_TEST_CYGDRIVE} =~ m{\A/}) {
        my $top = $ENV{STORE_TEST_CYGDRIVE};
        return sub { (my $x = $_[0]) =~ tr{\\}{/}; $x =~ s{\A([A-Za-z]):}{$top . '/' . lc $1}e; return $x };
    }
    no strict 'refs';
    return defined &{'Cygwin::win_to_posix_path'} ? \&{'Cygwin::win_to_posix_path'} : undef;
}

# Absolute, with . and .. folded (no symlink resolution: the path may not exist).
sub clean_path {
    my ($p, $base) = @_;
    return undef unless defined $p && $p ne '';
    $p = expand_tilde($p);
    if ($p !~ m{^/}) {
        $base //= do { require Cwd; Cwd::getcwd() };
        $p = "$base/$p";
    }
    my @out;
    for my $part (split m{/+}, $p) {
        next if $part eq '' || $part eq '.';
        if ($part eq '..') { pop @out; next }
        push @out, $part;
    }
    return '/' . join('/', @out);
}

# Real path of the nearest existing ancestor, then the rest appended.
sub real_path {
    my ($p) = @_;
    $p = clean_path($p);
    return undef unless defined $p;
    require Cwd;
    my $head = $p;
    my @tail;
    while ($head ne '/' && !-e $head) {
        unshift @tail, basename($head);
        $head = dirname($head);
    }
    # a path is bytes (§2.6 text encoding, SR 1.1): the real path and every tail part
    my $real = Cwd::abs_path(fsb($head)) // fsb($head);
    return @tail ? ($real eq '/' ? '' : $real) . '/' . join('/', map { fsb($_) } @tail) : $real;
}

sub mkdir_p {
    my ($dir) = @_;
    return 1 if -d $dir;
    my $parent = dirname($dir);
    mkdir_p($parent) unless -d $parent || $parent eq $dir;
    if (!mkdir($dir, 0700)) {
        return 1 if -d $dir;
        die "mkdir $dir: $!\n";
    }
    return 1;
}

# ---------------------------------------------------------------- files

# read_file(path, max?) -> bytes | undef. A folder is not a readable file (PF-5): open
# takes one for reading on macOS and the read gives '', which save-copy saved as a copy.
sub read_file {
    my ($path, $max) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    if (-d $fh) { close $fh; return undef }
    my $data = '';
    if (defined $max) {
        my $n = read($fh, $data, $max);
        return undef unless defined $n;
    } else {
        local $/;
        $data = <$fh>;
        $data = '' unless defined $data;
    }
    close $fh;
    return $data;
}

# Last $n bytes of a file (for transcript tails).
sub read_tail {
    my ($path, $n) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my $size = -s $fh;
    my $start = $size > $n ? $size - $n : 0;
    seek($fh, $start, SEEK_SET);
    local $/;
    my $data = <$fh>;
    close $fh;
    $data = '' unless defined $data;
    if ($start > 0) { $data =~ s/^[^\n]*\n// }    # drop the partial first line
    return $data;
}

sub _bytes {
    my ($s) = @_;
    return '' unless defined $s;
    if (utf8::is_utf8($s)) { my $c = $s; utf8::encode($c); return $c }
    return $s;
}

# to_bytes(text) -> the text as UTF-8 bytes (undef stays undef). Output lines are bytes:
# a character string joined with a byte literal such as `·` prints double-encoded.
sub to_bytes { return defined $_[0] ? _bytes($_[0]) : undef }

# Text encoding (MOD-SPEC §2.6, P5-FOLD A4): inside the helper text is characters, bytes
# are only at the edges. text(s) decodes an input once where it is read (UTF-8; bytes that
# are not UTF-8 stay as they are and so read as Latin-1, the CR-F2 rule); a character
# string passes unchanged, so a second call never decodes twice. fsb(path) is the path as
# bytes for a file-system call (a character path is encoded once).
sub text {
    my ($s) = @_;
    return undef unless defined $s;
    return $s if ref $s || utf8::is_utf8($s) || $s !~ /[\x80-\xff]/;
    my $c = $s;
    return utf8::decode($c) ? $c : $s;
}

sub fsb { return defined $_[0] ? _bytes($_[0]) : undef }

sub _write_all {
    my ($fh, $data) = @_;
    my $off = 0;
    my $len = length $data;
    while ($off < $len) {
        my $n = syswrite($fh, $data, $len - $off, $off);
        die "write: $!\n" unless defined $n;
        $off += $n;
    }
}

# Exclusive create. Returns 1 when created, 0 when the file already existed.
sub write_excl {
    my ($path, $data, $mode) = @_;
    $mode //= 0600;
    mkdir_p(dirname($path));
    my $fh;
    if (!sysopen($fh, $path, O_WRONLY | O_CREAT | O_EXCL, $mode)) {
        return 0 if $!{EEXIST};
        die "create $path: $!\n";
    }
    _write_all($fh, _bytes($data));
    close($fh) or die "close $path: $!\n";
    chmod $mode, $path;
    return 1;
}

# Whole-file write by temp + rename.
sub write_atomic {
    my ($path, $data, $mode) = @_;
    $mode //= 0600;
    mkdir_p(dirname($path));
    my $tmp = sprintf('%s.tmp-%d-%04x', $path, $$, int(rand(65536)));
    my $fh;
    sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, $mode) or die "create $tmp: $!\n";
    _write_all($fh, _bytes($data));
    close($fh) or die "close $tmp: $!\n";
    chmod $mode, $tmp;
    rename($tmp, $path) or do { my $e = $!; unlink $tmp; die "rename $path: $e\n" };
    return 1;
}

# One O_APPEND write of the whole buffer, under flock where the system has it.
sub append {
    my ($path, $data) = @_;
    mkdir_p(dirname($path));
    my $fh;
    sysopen($fh, $path, O_WRONLY | O_APPEND | O_CREAT, 0600) or die "open $path: $!\n";
    my $locked = eval { flock($fh, LOCK_EX) } ? 1 : 0;
    _write_all($fh, _bytes($data));
    flock($fh, LOCK_UN) if $locked;
    close($fh) or die "close $path: $!\n";
    return 1;
}

# copy_new(src, dst, mode => M, times => [atime, mtime], expect => [size, mtime]) -> bytes copied, or -1
# when dst exists. Never overwrites and never leaves a cut-off dst (STATE-ROOT `migrate`): the bytes go
# to a fresh temp name beside dst (.<name>.part-<pid>-<n>), which link() then also names dst (link fails
# when dst exists, so nothing is replaced); the temp name is removed either way. A failed copy dies with
# dst absent, so a rerun copies it again. A src whose size or mtime changes while it is copied (a
# session of an older version still writing it), or differs from expect (the size and mtime the
# caller read before), fails the same way: a rerun copies it whole.
sub copy_new {
    my ($src, $dst, %o) = @_;
    my $mode = $o{mode} // 0600;
    return -1 if -e $dst || -l $dst;
    open(my $in, '<:raw', $src) or die "open $src: $!\n";
    my @s0 = stat $in;
    my $dir = dirname($dst);
    mkdir_p($dir);
    my ($tmp, $out);
    for (1 .. 5) {
        my $t = "$dir/." . basename($dst) . ".part-$$-" . int(rand(1_000_000_000));
        if (sysopen($out, $t, O_WRONLY | O_CREAT | O_EXCL, $mode)) { $tmp = $t; last }
        die "create $t: $!\n" unless $!{EEXIST};
    }
    die "create a temp name beside $dst: none free\n" unless defined $tmp;
    my $total = 0;
    # test mode: STORE_TEST_COPY_FAIL_AFTER=N fails the write after N blocks (a disk that fills part way)
    my $fail = test_mode() && ($ENV{STORE_TEST_COPY_FAIL_AFTER} // '') =~ /\A[0-9]+\z/ ? $ENV{STORE_TEST_COPY_FAIL_AFTER} : undef;
    # test mode: STORE_TEST_COPY_GROW_AFTER=N appends to src after N blocks (a writer that is still at it)
    my $grow = test_mode() && ($ENV{STORE_TEST_COPY_GROW_AFTER} // '') =~ /\A[0-9]+\z/ ? $ENV{STORE_TEST_COPY_GROW_AFTER} : undef;
    my $blocks = 0;
    my $ok = eval {
        while (1) {
            my $n = sysread($in, my $buf, 1 << 16);
            die "read $src: $!\n" unless defined $n;
            last if $n == 0;
            die "write: no space left (test)\n" if defined $fail && $blocks++ >= $fail;
            _write_all($out, $buf);
            $total += $n;
            if (defined $grow && $blocks++ >= $grow) { undef $grow; if (open(my $g, '>>', $src)) { print $g "more\n"; close $g } }
        }
        my @s1 = stat $in;
        die "changed while it was copied\n"
            if !@s0 || !@s1 || $s1[7] != $s0[7] || $s1[9] != $s0[9] || $total != $s1[7]
            || (ref $o{expect} eq 'ARRAY' && ($o{expect}[0] != $s1[7] || $o{expect}[1] != $s1[9]));
        close($out) or die "close $tmp: $!\n";
        chmod $mode, $tmp;
        utime($o{times}[0], $o{times}[1], $tmp) if ref $o{times} eq 'ARRAY';
        1;
    };
    my $err = $@;
    close $in;
    if (!$ok) { close $out; unlink $tmp; die $err }
    my $linked = link($tmp, $dst);
    my ($exists, $why) = ($!{EEXIST}, "$!");
    unlink $tmp;
    return $total if $linked;
    return -1 if $exists;
    die "link $dst: $why\n";
}

# Stream copy (File::Copy is off the floor). Returns bytes copied.
sub copy_file {
    my ($src, $dst, %o) = @_;
    my $mode = $o{mode} // 0600;
    open(my $in, '<:raw', $src) or die "open $src: $!\n";
    mkdir_p(dirname($dst));
    my $out;
    my $flags = O_WRONLY | O_CREAT | ($o{excl} ? O_EXCL : O_TRUNC);
    if (!sysopen($out, $dst, $flags, $mode)) {
        return -1 if $o{excl} && $!{EEXIST};
        die "create $dst: $!\n";
    }
    my $total = 0;
    while (1) {
        my $n = sysread($in, my $buf, 1 << 16);
        die "read $src: $!\n" unless defined $n;
        last if $n == 0;
        _write_all($out, $buf);
        $total += $n;
    }
    close $in;
    close($out) or die "close $dst: $!\n";
    chmod $mode, $dst;
    return $total;
}

sub list_dir {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return ();
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    return sort @e;
}

# list_dir_max(dir, max) -> at most max entries of dir (no . or ..), in readdir order;
# reading stops at max, so a huge folder costs no more than the bound.
sub list_dir_max {
    my ($dir, $max) = @_;
    return () unless defined $max && $max > 0;
    opendir(my $dh, $dir) or return ();
    my @e;
    while (defined(my $x = readdir $dh)) {
        next if $x eq '.' || $x eq '..';
        push @e, $x;
        last if @e >= $max;
    }
    closedir $dh;
    return @e;
}

# ---------------------------------------------------------------- processes

sub which {
    my ($name) = @_;
    return $name if $name =~ m{/} && -x $name;
    for my $d (split /:/, ($ENV{PATH} // '')) {
        next if $d eq '';
        my $p = "$d/$name";
        return $p if -f $p && -x _;
    }
    return undef;
}

# Run argv with no shell. Options: timeout_ms (default 5000), stdin (bytes),
# env (hashref: value undef = unset), cwd, max_out (bytes, default 4 MiB).
# Returns {exit, out, timed_out, ms, started}. stderr goes to /dev/null.
sub run {
    my ($argv, %o) = @_;
    my $timeout = $o{timeout_ms} // 5000;
    my $max = $o{max_out} // 4 * 1024 * 1024;
    my $t0 = clock_ms();
    my ($out_r, $out_w, $in_r, $in_w);
    pipe($out_r, $out_w) or return { exit => -1, out => '', timed_out => 0, ms => 0, started => 0 };
    my $stdin = $o{stdin};
    if (defined $stdin) { pipe($in_r, $in_w) or return { exit => -1, out => '', timed_out => 0, ms => 0, started => 0 } }
    my $pid = fork();
    if (!defined $pid) {
        return { exit => -1, out => '', timed_out => 0, ms => 0, started => 0 };
    }
    if ($pid == 0) {
        eval {
            setpgrp(0, 0);
            close $out_r;
            open(STDOUT, '>&', $out_w) or POSIX::_exit(126);
            open(STDERR, '>', '/dev/null');
            if (defined $stdin) { close $in_w; open(STDIN, '<&', $in_r) or POSIX::_exit(126) }
            else { open(STDIN, '<', '/dev/null') }
            if ($o{env}) {
                for my $k (keys %{ $o{env} }) {
                    if (defined $o{env}{$k}) { $ENV{$k} = $o{env}{$k} } else { delete $ENV{$k} }
                }
            }
            if (defined $o{cwd}) { chdir($o{cwd}) or POSIX::_exit(126) }
            exec { $argv->[0] } @$argv;
        };
        POSIX::_exit(127);
    }
    close $out_w;
    # Killed while we wait (a hook timeout): take the child's process group along, so no
    # git or queue_cmd process outlives the helper.
    my $reap = sub { kill 'TERM', -$pid; kill 'TERM', $pid; POSIX::_exit(128 + 15) };
    local $SIG{TERM} = $reap;
    local $SIG{HUP} = $reap;
    local $SIG{INT} = $reap;
    if (defined $stdin) {
        close $in_r;
        local $SIG{PIPE} = 'IGNORE';
        my $data = _bytes($stdin);
        my $off = 0;
        while ($off < length $data) {
            my $n = syswrite($in_w, $data, length($data) - $off, $off);
            last unless defined $n && $n > 0;
            $off += $n;
        }
        close $in_w;
    }
    my $out = '';
    my $timed_out = 0;
    my $rin = '';
    vec($rin, fileno($out_r), 1) = 1;
    while (1) {
        my $left = $timeout - (clock_ms() - $t0);
        if ($left <= 0) { $timed_out = 1; last }
        my $rout;
        my $n = select($rout = $rin, undef, undef, $left / 1000);
        if ($n < 0) { next if $!{EINTR}; last }
        next if $n == 0;
        my $got = sysread($out_r, my $buf, 65536);
        last if !defined $got || $got == 0;
        $out .= $buf if length($out) < $max;
    }
    close $out_r;
    if ($timed_out) {
        kill 'TERM', -$pid;
        kill 'TERM', $pid;
        my $waited = 0;
        while ($waited < 300) {
            last if waitpid($pid, POSIX::WNOHANG()) > 0;
            sleep_ms(20);
            $waited += 20;
        }
        if ($waited >= 300) { kill 'KILL', -$pid; kill 'KILL', $pid; waitpid($pid, 0) }
        return { exit => -1, out => $out, timed_out => 1, ms => clock_ms() - $t0, started => 1 };
    }
    waitpid($pid, 0);
    my $st = $?;
    my $exit = ($st & 127) ? 128 + ($st & 127) : ($st >> 8);
    return { exit => $exit, out => $out, timed_out => 0, ms => clock_ms() - $t0, started => ($exit == 127 ? 0 : 1) };
}

# ---------------------------------------------------------------- test trace

sub trace {
    my ($step) = @_;
    return unless test_mode();
    my $f = $ENV{STORE_TEST_TRACE};
    return unless defined $f && $f ne '';
    eval { append($f, "$step\n") };
}

sub rand_hex {
    my ($n) = @_;
    my $bytes = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, int(($n + 1) / 2));
        close $fh;
    }
    if (length($bytes) < int(($n + 1) / 2)) {
        $bytes = join '', map { chr(int(rand(256))) } 1 .. int(($n + 1) / 2);
    }
    return substr(unpack('H*', $bytes), 0, $n);
}

1;

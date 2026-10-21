package watch::cache;
# lib/watch/cache.pm: the watcher's persisted incremental read state
# (ROOT-RULINGS F2-4; WATCHER-SPEC W9). Owner: WP-watch.
#
# The rules read a fixed list of row kinds (watch::rules::KINDS) from this
# session's streams (classic, mod, the rollup, the alerts log) and records
# (dispatch/, events/). Instead of decoding every stream on every Stop, the
# Stop keeps under <watch>/<sid>/watch-cache/:
#   rows.jsonl   the kept rows, verbatim, one per line, each wrapped as
#                {"s":<source>,"r":<row>} (dir sources add "f":<file name>).
#                Append-only; only its first `len` bytes count.
#   state.json   {v, kinds, len, src: {<stream>: {ino, off}}, dir: {<dir>: {<file>: 1}}},
#                written atomically (temp file + rename), mode 0600.
# Only the Stop that holds the sweeper's lock writes them (one writer per sid).
# A stream line is decoded only when its "ev" is a kept kind, and each stream
# is read from the stored offset, whole lines only. A stream that was replaced
# (another inode) or shrank, another kind list or version, or a rows file
# shorter than `len` rebuilds the cache from the start.
# Reading stops at the deadline at a whole line: what was read is kept, and
# the load says it is incomplete, so no rule runs on part of a stream.
use strict;
use warnings;
use Fcntl qw(O_RDWR O_CREAT SEEK_END);
use watch::ctx;
use watch::io;
use watch::json;

our $V = 1;
my @SRC = qw(classic mod rollup alerts);
my @DIR = qw(dispatch events);

sub dir_of { return watch::ctx::sid_dir($_[0]) . '/watch-cache' }

sub _streams {
    my ($ctx) = @_;
    return (classic => watch::ctx::classic_log($ctx), mod => watch::ctx::mod_log($ctx),
            rollup => watch::ctx::sid_dir($ctx) . '/compactions.jsonl', alerts => watch::ctx::alerts_log($ctx));
}

sub _dirs {
    my ($ctx) = @_;
    my $d = watch::ctx::sid_dir($ctx);
    return (dispatch => "$d/dispatch", events => "$d/events");
}

sub _ev_re {
    my (@ev) = @_;
    my $alt = join('|', map { quotemeta } sort @ev);
    return qr/"ev"\s*:\s*"(?:$alt)"/;
}

sub _empty_rows { return { map { $_ => [] } @SRC, @DIR } }

sub _fresh_state { my ($sig) = @_; return { v => $V, kinds => $sig, len => 0, src => {}, dir => {} } }

# load(ctx, kinds => [ev...], deadline => mono seconds) -> cache
#   {rows => {classic|mod|rollup|alerts|dispatch|events => [rows]}, complete => 0|1, ...}
sub load {
    my ($ctx, %o) = @_;
    my @kinds = @{ $o{kinds} || [] };
    my $sig = watch::io::fnv8(join(',', $V, sort @kinds));
    my $dir = dir_of($ctx);
    my %C = (ctx => $ctx, dir => $dir, rows => _empty_rows(), new => '', complete => 1, rebuilt => 0,
             kinds => { map { $_ => 1 } @kinds }, kind_re => _ev_re(@kinds), alert_re => _ev_re('alert'));
    my %streams = _streams($ctx);
    my $st = watch::io::read_json_file("$dir/state.json");
    my $ok = ref $st eq 'HASH' && ($st->{v} // 0) == $V && ($st->{kinds} // '') eq $sig
          && defined $st->{len} && !ref $st->{len} && $st->{len} =~ /\A[0-9]+\z/
          && ref $st->{src} eq 'HASH' && ref $st->{dir} eq 'HASH';
    if ($ok) {
        for my $name (@SRC) {
            my $s = $st->{src}{$name};
            next unless ref $s eq 'HASH';
            my @f = stat $streams{$name};
            my $off = $s->{off} // 0;
            # A stream that is gone, replaced or shorter than what was read.
            if (!@f) { $ok = 0 if $off > 0; next }
            $ok = 0 if ($s->{ino} // -1) != $f[1] || $f[7] < $off;
        }
    }
    $ok = _read_rows(\%C, "$dir/rows.jsonl", $st->{len}) if $ok;
    unless ($ok) {
        $st = _fresh_state($sig);
        $C{rows} = _empty_rows();
        $C{rebuilt} = 1;
    }
    $C{state} = $st;
    for my $name (@SRC) {
        last unless $C{complete};
        _read_stream(\%C, $name, $streams{$name}, $o{deadline});
    }
    my %dirs = _dirs($ctx);
    for my $name (@DIR) {
        last unless $C{complete};
        _read_dir(\%C, $name, $dirs{$name}, $o{deadline});
    }
    return \%C;
}

sub _read_rows {
    my ($C, $path, $len) = @_;
    return 1 if $len == 0;
    open(my $fh, '<:raw', $path) or return 0;
    my $data = '';
    my $got = read($fh, $data, $len);
    close $fh;
    return 0 unless defined $got && $got == $len && substr($data, -1) eq "\n";
    for my $line (split /\n/, $data) {
        my $w = eval { watch::json::decode($line) };
        return 0 unless ref $w eq 'HASH' && defined $w->{s} && $C->{rows}{ $w->{s} } && ref $w->{r} eq 'HASH';
        _dispatch_nonce($w->{r}, $w->{f}) if $w->{s} eq 'dispatch';
        push @{ $C->{rows}{ $w->{s} } }, $w->{r};
    }
    return 1;
}

sub _deadline_hit {
    my ($C, $deadline) = @_;
    return 0 unless defined $deadline && watch::io::mono() >= $deadline;
    $C->{complete} = 0;
    return 1;
}

sub _read_stream {
    my ($C, $name, $path, $deadline) = @_;
    my @f = stat $path;
    return unless @f;
    my $s = $C->{state}{src}{$name} ||= {};
    my $off = (defined $s->{off} && ($s->{ino} // -1) == $f[1]) ? $s->{off} : 0;
    $s->{ino} = $f[1];
    $s->{off} = $off;
    return if $f[7] <= $off;
    open(my $fh, '<:raw', $path) or return;
    seek($fh, $off, 0);
    my $want = $name eq 'alerts' ? $C->{alert_re} : $name eq 'rollup' ? undef : $C->{kind_re};
    my $n = 0;
    while (1) {
        last if ++$n % 64 == 0 && _deadline_hit($C, $deadline);
        my $line = <$fh>;
        # A last line without its newline is still being written: read it next time.
        last unless defined $line && substr($line, -1) eq "\n";
        $off += length $line;
        next if $want && $line !~ $want;
        (my $raw = $line) =~ s/[\r\n]+\z//;
        next unless $raw =~ /\S/;
        my $r = eval { watch::json::decode($raw) };
        next unless ref $r eq 'HASH';
        if ($name eq 'alerts') { next unless ($r->{ev} // '') eq 'alert' }
        elsif ($name ne 'rollup') { next unless $C->{kinds}{ $r->{ev} // '' } }
        push @{ $C->{rows}{$name} }, $r;
        $C->{new} .= '{"s":"' . $name . '","r":' . $raw . "}\n";
    }
    close $fh;
    $s->{off} = $off;
}

sub _dispatch_nonce {
    my ($r, $f) = @_;
    $r->{nonce} //= $1 if defined $f && $f =~ /\A([0-9a-f]{8})\.json\z/;
}

# Records are written once (exclusive create): a file is read until it decodes,
# then never again.
sub _read_dir {
    my ($C, $name, $dir, $deadline) = @_;
    my $seen = $C->{state}{dir}{$name} ||= {};
    my $re = $name eq 'dispatch' ? qr/\A[0-9a-f]{8}\.json\z/ : qr/\.json\z/;
    my $n = 0;
    for my $f (watch::io::list_dir($dir)) {
        next unless $f =~ $re && !$seen->{$f};
        last if ++$n % 32 == 0 && _deadline_hit($C, $deadline);
        my $raw = watch::io::slurp("$dir/$f", 1 << 20);
        next unless defined $raw && length $raw;
        my $r = eval { watch::json::decode($raw) };
        next unless ref $r eq 'HASH';
        $seen->{$f} = 1;
        next if $name eq 'events' && !$C->{kinds}{ $r->{ev} // '' };
        # A JSON text that decoded holds no raw newline inside a string.
        (my $one = $raw) =~ s/[\r\n]+/ /g;
        $one =~ s/\s+\z//;
        _dispatch_nonce($r, $f) if $name eq 'dispatch';
        push @{ $C->{rows}{$name} }, $r;
        $C->{new} .= '{"f":' . watch::json::encode($f) . ',"r":' . $one . ',"s":"' . $name . "\"}\n";
    }
}

# Persist what load() read. Only the Stop that holds the sweeper's lock calls it.
sub save {
    my ($C) = @_;
    return 0 unless $C && $C->{state};
    my $dir = $C->{dir};
    watch::io::mkdir_p($dir) or return 0;
    my $st = $C->{state};
    my $len = $C->{rebuilt} ? 0 : $st->{len};
    my $path = "$dir/rows.jsonl";
    my $old = umask 077;
    my $ok = sysopen(my $fh, $path, O_RDWR | O_CREAT, 0600);
    umask $old;
    return 0 unless $ok;
    # Drop any tail that state.json does not vouch for, then append.
    my $fine = truncate($fh, $len) && defined sysseek($fh, 0, SEEK_END);
    if ($fine && length $C->{new}) {
        my $w = syswrite($fh, $C->{new});
        $fine = defined $w && $w == length $C->{new};
    }
    close $fh;
    return 0 unless $fine;
    $st->{len} = $len + length $C->{new};
    $C->{new} = '';
    $C->{rebuilt} = 0;
    return watch::io::write_atomic("$dir/state.json", watch::json::encode($st) . "\n");
}

1;

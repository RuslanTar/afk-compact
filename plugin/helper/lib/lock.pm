package lock;
# lib/lock.pm: advisory locks for read-modify-write of our own files.
# lock::with(path, owner, fn):
#   flock(LOCK_EX) on the lock file (released by the kernel when a holder dies),
#   then the owner record inside it: a record left by another holder whose pid is
#   dead, or whose start time differs, is stale -> taken over, one `lock_stale` row.
#   A record of a live holder is never broken: we wait up to `wait_ms`, then give up. A
#   start time this call cannot read is no difference (identity::alive): that
#   holder counts as live.
# owner = {sid, actor}; pid and start time are this helper process's, host from uname.
use strict;
use warnings;
use utf8;
use Fcntl qw(O_RDWR O_CREAT LOCK_EX LOCK_NB LOCK_UN SEEK_SET);

sub _read_record {
    my ($fh) = @_;
    seek($fh, 0, SEEK_SET);
    local $/;
    my $raw = <$fh>;
    return undef unless defined $raw && $raw =~ /\S/;
    my $j = eval { jsonc::decode($raw) };
    return ref $j eq 'HASH' ? $j : { corrupt => 1 };
}

sub _write_record {
    my ($fh, $rec) = @_;
    seek($fh, 0, SEEK_SET);
    truncate($fh, 0);
    my $line = defined $rec ? jsonc::encode_bytes($rec) . "\n" : '';
    syswrite($fh, $line) if length $line;
}

# with(path, owner, fn, wait_ms => 5000) -> fn's return value; dies "lock-timeout"
sub with {
    my ($path, $owner, $fn, %o) = @_;
    my $wait = $o{wait_ms} // 5000;
    util::mkdir_p(util::dirname($path));
    my $fh;
    sysopen($fh, $path, O_RDWR | O_CREAT, 0600) or die "lock open $path: $!\n";
    my $t0 = util::clock_ms();
    my $have_flock = 1;
    while (1) {
        my $ok = flock($fh, LOCK_EX | LOCK_NB);
        last if $ok;
        if (!$!{EWOULDBLOCK} && !$!{EAGAIN}) { $have_flock = 0; last }    # no flock here: records only
        die "lock-timeout\n" if util::clock_ms() - $t0 > $wait;
        util::sleep_ms(10);
    }
    my $me = { sid => $owner->{sid}, actor => $owner->{actor} // 'unknown', pid => $$,
               pid_lstart => identity::start_time($$), host => identity::host(), ts => util::iso(util::now()) };
    while (1) {
        my $rec = _read_record($fh);
        last unless $rec;
        my $stale;
        if ($rec->{corrupt}) { $stale = 1 }
        elsif (defined $rec->{host} && $rec->{host} ne $me->{host}) { $stale = 0 }    # cannot check another host
        else { $stale = identity::alive($rec->{pid}, $rec->{pid_lstart}) ? 0 : 1 }
        if (!$stale && defined $rec->{pid} && $rec->{pid} == $$) { last }
        if ($stale) {
            my $why = $rec->{corrupt} ? 'corrupt' : (defined $rec->{pid} && (kill(0, $rec->{pid}) || $!{EPERM})) ? 'start-time' : 'dead';
            rc::emit('lock_stale', [lock => util::basename($path), reason => $why]) if $o{log} // 1;
            last;
        }
        # A live holder without flock (no-flock file system): never break it.
        if (util::clock_ms() - $t0 > $wait) { flock($fh, LOCK_UN) if $have_flock; close $fh; die "lock-timeout\n" }
        util::sleep_ms(20);
    }
    _write_record($fh, $me);
    my @r = eval { $fn->() };
    my $err = $@;
    _write_record($fh, undef);
    flock($fh, LOCK_UN) if $have_flock;
    close $fh;
    die $err if $err;
    return wantarray ? @r : $r[0];
}

1;

package sidecar;
# lib/sidecar.pm: background sidecar ring (MOD-SPEC §7, HK-23; WATCHER §6.5).
# Owner: WP-core. Stop and SubagentStop write ids, kinds and status from
# background_tasks and the ids of session_crons (never last_assistant_message or
# task text) into 20 slot files <watch>/<sid>/bg/slot-<k>.json, only when the set
# hash changes; k = write counter mod 20, kept in the slot lock under flock.
use strict;
use warnings;
use Fcntl qw(O_RDWR O_CREAT LOCK_EX LOCK_UN SEEK_SET);

our $SLOTS = 20;
my $ID_RE = qr/^[A-Za-z0-9._:\/-]{1,128}$/;

sub _clean { my ($v, $re) = @_; return (defined $v && !ref $v && $v =~ ($re // qr/^[a-z0-9_ -]{1,40}$/i)) ? $v : undef }

sub tasks_of {
    my ($payload) = @_;
    my (%seen, @tasks, @crons);
    for my $t (@{ ref $payload->{background_tasks} eq 'ARRAY' ? $payload->{background_tasks} : [] }) {
        next unless ref $t eq 'HASH';
        my $id = _clean($t->{id}, $ID_RE) // next;
        next if $seen{"t:$id"}++;
        my $out = _clean($t->{output_path} // $t->{outputFilePath}, qr{^/[^\n]{1,512}$});
        push @tasks, jsonc::obj(id => $id, type => _clean($t->{type}) // 'other', status => _clean($t->{status}) // 'other',
                                output_path => $out);
    }
    for my $c (@{ ref $payload->{session_crons} eq 'ARRAY' ? $payload->{session_crons} : [] }) {
        next unless ref $c eq 'HASH';
        my $id = _clean($c->{id}, $ID_RE) // next;
        next if $seen{"c:$id"}++;
        push @crons, $id;
    }
    @tasks = sort { ${$a}[1] cmp ${$b}[1] } @tasks;
    @crons = sort @crons;
    return (\@tasks, \@crons);
}

# write(sid_dir, payload, source) -> slot index written, or undef when unchanged
sub write {
    my ($sid_dir, $payload, $source) = @_;
    my ($tasks, $crons) = tasks_of($payload);
    my $hash = substr(sha::hex256(jsonc::encode([$tasks, $crons])), 0, 8);
    my $dir = "$sid_dir/bg";
    util::mkdir_p($dir);
    my $fh;
    sysopen($fh, "$dir/slot.lock", O_RDWR | O_CREAT, 0600) or die "slot lock: $!\n";
    flock($fh, LOCK_EX);
    seek($fh, 0, SEEK_SET);
    local $/;
    my $raw = <$fh>;
    my $st = (defined $raw && $raw =~ /\S/) ? (eval { jsonc::decode($raw) } || {}) : {};
    my $k;
    if (($st->{last} // '') ne $hash) {
        my $n = 0 + ($st->{n} // 0);
        $k = $n % $SLOTS;
        my $slot = jsonc::obj(v => 1, ts => util::iso_ms(util::now()), seq => $n + 1, set_hash => $hash,
                              source => $source, tasks => $tasks, crons => $crons);
        util::write_atomic("$dir/slot-$k.json", jsonc::encode_bytes($slot) . "\n", 0600);
        seek($fh, 0, SEEK_SET);
        truncate($fh, 0);
        syswrite($fh, jsonc::encode_bytes({ n => $n + 1, last => $hash }) . "\n");
    }
    flock($fh, LOCK_UN);
    close $fh;
    return $k;
}

# newest(sid_dir) -> slot object of the highest seq, or undef
sub newest {
    my ($sid_dir) = @_;
    my $best;
    for my $f (util::list_dir("$sid_dir/bg")) {
        next unless $f =~ /^slot-\d+\.json$/;
        my $raw = util::read_file("$sid_dir/bg/$f") // next;
        my $j = eval { jsonc::decode($raw) } or next;
        $best = $j if ref $j eq 'HASH' && (!$best || ($j->{seq} // 0) > ($best->{seq} // 0));
    }
    return $best;
}

1;

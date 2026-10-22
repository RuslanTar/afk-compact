package sessions;
# lib/sessions.pm: per-process records and lineage (MOD-SPEC §7, HK-49, OD-16).
# Owner: WP-core. All records are write-once by exclusive create.
#   <root>/.sessions/by-pid/<pid>-<lstart_epoch>.live-<sid8>.json  {pid, pid_lstart, host, session_id, cwd, worktree, source, ts}
#     (host added for the cross-session finish, MOD-SPEC §5.8 / C-STORE D8; additive)
#   <root>/.sessions/by-pid/<pid>-<lstart_epoch>.ended-<sid8>.json {session_id, reason, ts}
#   <root>/.sessions/<sid>.lineage.json {previous_session_id, lineage_reason}
use strict;
use warnings;
use utf8;

sub dir { return rc::root() . '/.sessions' }
sub by_pid { return dir() . '/by-pid' }

sub _key {
    my ($c) = @_;
    my $e = identity::lstart_epoch($c->{lstart});
    return defined $e ? "$c->{pid}-$e" : "$c->{pid}-0";
}

sub write_live {
    my ($sid, $cwd, $worktree, $source) = @_;
    my $c = rc::claude();
    my $f = by_pid() . '/' . _key($c) . '.live-' . substr($sid, 0, 8) . '.json';
    my $rec = jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, host => identity::host(), session_id => $sid, cwd => $cwd,
                         worktree => $worktree, source => $source, ts => util::iso(util::now()));
    return util::write_excl($f, jsonc::encode_bytes($rec) . "\n", 0600);
}

sub write_ended {
    my ($sid, $reason) = @_;
    my $c = rc::claude();
    my $f = by_pid() . '/' . _key($c) . '.ended-' . substr($sid, 0, 8) . '.json';
    my $rec = jsonc::obj(session_id => $sid, reason => $reason, ts => util::iso(util::now()));
    return util::write_excl($f, jsonc::encode_bytes($rec) . "\n", 0600);
}

# Newest `ended-` record with reason clear for this process (pid + start time).
sub last_cleared {
    my $c = rc::claude();
    my $k = _key($c);
    my ($best, $best_t);
    for my $f (util::list_dir(by_pid())) {
        next unless index($f, "$k.ended-") == 0;
        my $raw = util::read_file(by_pid() . "/$f") // next;
        my $j = eval { jsonc::decode($raw) } or next;
        next unless ref $j eq 'HASH' && ($j->{reason} // '') eq 'clear';
        my $t = util::parse_iso($j->{ts} // '') // 0;
        ($best, $best_t) = ($j, $t) if !defined $best_t || $t >= $best_t;
    }
    return $best;
}

# lineage(sid, source) for clear|fork -> {previous_session_id, lineage_reason} or undef
sub write_lineage {
    my ($sid, $source) = @_;
    my $f = dir() . "/$sid.lineage.json";
    return { exists => 1 } if -e $f;
    my $prev;
    my $e = last_cleared();
    $prev = $e->{session_id} if $e && ($e->{session_id} // '') ne $sid;
    if (!defined $prev) {
        return undef unless $source eq 'fork';
        $prev = 'unknown';
    }
    my $rec = jsonc::obj(previous_session_id => $prev, lineage_reason => $source);
    util::write_excl($f, jsonc::encode_bytes($rec) . "\n", 0600);
    return { previous_session_id => $prev, lineage_reason => $source };
}

sub lineage {
    my ($sid) = @_;
    my $raw = util::read_file(dir() . "/$sid.lineage.json") // return undef;
    my $j = eval { jsonc::decode($raw) };
    return ref $j eq 'HASH' ? $j : undef;
}

# records_for(sid) -> {n, live => [records with no ended- twin], newest => record | undef}:
# the per-process records of one session (file names by sid8, the full id checked inside).
sub records_for {
    my ($sid) = @_;
    my $sid8 = substr($sid // '', 0, 8);
    my (%ended, @live, $newest, $newest_t);
    my $n = 0;
    my @files = util::list_dir(by_pid());
    for my $f (@files) {
        next unless $f =~ /^(\d+-\d+)\.(live|ended)-\Q$sid8\E\.json$/;
        my ($key, $kind) = ($1, $2);
        my $raw = util::read_file(by_pid() . "/$f") // next;
        my $j = eval { jsonc::decode($raw) };
        next unless ref $j eq 'HASH' && ($j->{session_id} // '') eq $sid;
        $n++;
        if ($kind eq 'ended') { $ended{$key} = 1; next }
        push @live, { %$j, _key => $key };
        my $t = util::parse_iso($j->{ts} // '') // 0;
        ($newest, $newest_t) = ($j, $t) if !defined $newest_t || $t >= $newest_t;
    }
    return { n => $n, live => [grep { !$ended{ $_->{_key} } } @live], newest => $newest };
}

# record_live(record) -> 1 when a live- record with no ended- twin still counts as live
# (MOD-SPEC §5.8). The literal RRP-05 reading: only an ended- record ends a session.
sub record_live {
    my ($rec) = @_;
    return 1;
}

# ended(sid) -> 1 when another session may finish sid's stashes (MOD-SPEC §5.8 "Eligible"):
# sid has at least one per-process record and none of them is live. A session with no
# record at all is never touched.
sub ended {
    my ($sid) = @_;
    my $r = records_for($sid);
    return 0 unless $r->{n};
    return (grep { record_live($_) } @{ $r->{live} }) ? 0 : 1;
}

# live_peers() -> [{session_id, pid, pid_lstart, cwd, worktree}] : a session is
# live when its pid runs with the same start time and it has no ended- record.
sub live_peers {
    my %ended;
    my @live;
    for my $f (util::list_dir(by_pid())) {
        if ($f =~ /^(\d+-\d+)\.ended-([^.]+)\.json$/) { $ended{"$1/$2"} = 1; next }
    }
    for my $f (util::list_dir(by_pid())) {
        next unless $f =~ /^(\d+-\d+)\.live-([^.]+)\.json$/;
        next if $ended{"$1/$2"};
        my $raw = util::read_file(by_pid() . "/$f") // next;
        my $j = eval { jsonc::decode($raw) } or next;
        next unless ref $j eq 'HASH';
        next unless identity::alive($j->{pid}, $j->{pid_lstart});
        push @live, $j;
    }
    return \@live;
}

1;

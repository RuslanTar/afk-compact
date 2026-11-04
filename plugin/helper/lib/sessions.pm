package sessions;
# lib/sessions.pm: per-process records and lineage (MOD-SPEC §7, HK-49, OD-16).
# Owner: WP-core. All records are write-once by exclusive create.
#   <root>/.sessions/by-pid/<pid>-<lstart_epoch>.live-<sid8>.json  {pid, pid_lstart, host, session_id, cwd, worktree, head, source, ts}
#     (host added for the cross-session finish, MOD-SPEC §5.8 / C-STORE D8; additive)
#     (head: the work tree's HEAD commit when the record was written, null outside git or on an
#     unborn branch; owner xxxxxxxx-08, the start HEAD that `risk` compares build files with; additive)
#   <root>/.sessions/by-pid/<pid>-<lstart_epoch>.ended-<sid8>.json {session_id, reason, ts}
#     (reason `gone`: written when the same session starts again in another process and the
#     earlier one ended with no SessionEnd, close_gone; its ts is that later start, not the end,
#     which is unknown)
#   <root>/.sessions/<sid>.lineage.json {previous_session_id, lineage_reason}
#   prune_records: once a day (with the load prune, lib/plugver.pm) drops a session's later live-
#     records of ended processes, over a week old, and their ended- twins; never a session's
#     earliest record, one of a session with a stash, or one of a process that may still run.
use strict;
use warnings;
use utf8;

sub dir { return rc::root() . '/.sessions' }
sub by_pid { return dir() . '/by-pid' }
# STATE-ROOT: the readers below also read the legacy root's records and lineage (rc::read_roots, the
# effective root first); every write goes to dir() and by_pid() only.
sub read_dirs { return map { "$_/.sessions" } rc::read_roots() }
# _pid_files() -> ([folder, name] …): the by-pid file names of every read root.
sub _pid_files {
    my @out;
    for my $d (map { "$_/by-pid" } read_dirs()) { push @out, map { [ $d, $_ ] } util::list_dir($d) }
    return @out;
}

sub _key {
    my ($c) = @_;
    my $e = identity::lstart_epoch($c->{lstart});
    return defined $e ? "$c->{pid}-$e" : "$c->{pid}-0";
}

sub write_live {
    my ($sid, $cwd, $worktree, $source, $head) = @_;
    my $c = rc::claude();
    my $f = by_pid() . '/' . _key($c) . '.live-' . substr($sid, 0, 8) . '.json';
    # ts in milliseconds when Time::HiRes loads (own_start: a row from the record's second may be
    # the owner's launch prompt); without it no fraction is written, and own_start reads the
    # record as coarse (that second is decided by row order, never by time).
    my $now = util::now();
    my $rec = jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, host => identity::host(), session_id => $sid, cwd => $cwd,
                         worktree => $worktree, head => $head, source => $source, ts => (util::stamp_ms() ? util::iso_ms($now) : util::iso($now)));
    return util::write_excl($f, jsonc::encode_bytes($rec) . "\n", 0600);
}

sub write_ended {
    my ($sid, $reason) = @_;
    my $c = rc::claude();
    my $f = by_pid() . '/' . _key($c) . '.ended-' . substr($sid, 0, 8) . '.json';
    my $rec = jsonc::obj(session_id => $sid, reason => $reason, ts => util::iso(util::now()));
    return util::write_excl($f, jsonc::encode_bytes($rec) . "\n", 0600);
}

our $CLOSE_GONE_MS = 300;

# _gone(pid, lstart) -> 1 only when the process surely ended: no such pid, or a start time
# read now that differs from the recorded one. An unreadable start time is not proof.
sub _gone {
    my ($pid, $lstart) = @_;
    return 0 unless defined $pid && !ref $pid && $pid =~ /^\d+$/ && $pid > 0;
    return 1 unless kill(0, $pid) || $!{EPERM};
    return 0 unless defined $lstart && !ref $lstart && $lstart ne '';
    my $now = identity::start_time($pid);
    return defined $now && $now ne $lstart ? 1 : 0;
}

# close_gone(sid, budget_ms => N) -> the number of ended- records written. A process that
# stops with no SessionEnd leaves its live- record behind: a background session the supervisor
# moved to a new version (probe 2026-10-27, P4: SessionStart resume in the new process, none
# ended in the old one), `claude --resume` after a crash. When sid starts again, every live-
# record of sid on this host with no ended- twin whose process is gone (_gone) gets one,
# reason `gone`, within the budget. Only sid's own records: another session's record may be a
# process this one cannot see (another pid namespace under the same host name), and its
# liveness is judged when it is read (record_live). Records of another host, or with no host,
# are left alone; no record is deleted here (own_start reads every live- record; prune_records
# keeps each session's earliest).
sub close_gone {
    my ($sid, %o) = @_;
    return 0 unless defined $sid && !ref $sid && length($sid) >= 8;
    my $sid8 = substr($sid, 0, 8);
    my $end = util::clock_ms() + ($o{budget_ms} // $CLOSE_GONE_MS);
    my $dir = by_pid();
    my @pf = _pid_files();
    my %ended = map { $_->[1] =~ /^(\d+-\d+)\.ended-([^.]+)\.json$/ ? ("$1/$2" => 1) : () } @pf;
    my $host = identity::host();
    my $me = rc::claude();
    my $n = 0;
    for my $pf (@pf) {
        my ($fd, $f) = @$pf;
        last if util::clock_ms() > $end;
        next unless $f =~ /^((\d+)-\d+)\.live-\Q$sid8\E\.json$/;
        my ($key, $pid) = ($1, $2);
        next if $ended{"$key/$sid8"} || ($me && defined $me->{pid} && $me->{pid} == $pid);
        my $j = eval { jsonc::decode(util::read_file("$fd/$f") // '') };
        next unless ref $j eq 'HASH' && ($j->{session_id} // '') eq $sid;
        next unless defined $j->{host} && !ref $j->{host} && $j->{host} eq $host;
        next unless _gone($j->{pid}, $j->{pid_lstart});
        my $rec = jsonc::obj(session_id => $j->{session_id}, reason => 'gone', ts => util::iso(util::now()));
        $ended{"$key/$sid8"} = 1;
        # the ended- twin of a legacy record goes to the effective root too (never the legacy one)
        util::mkdir_p($dir) if $fd ne $dir;
        $n++ if util::write_excl("$dir/$key.ended-$sid8.json", jsonc::encode_bytes($rec) . "\n", 0600);
    }
    return $n;
}

# Newest `ended-` record with reason clear for this process (pid + start time).
sub last_cleared {
    my $c = rc::claude();
    my $k = _key($c);
    my ($best, $best_t);
    for my $pf (_pid_files()) {
        my ($fd, $f) = @$pf;
        next unless index($f, "$k.ended-") == 0;
        my $raw = util::read_file("$fd/$f") // next;
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
    return { exists => 1 } if grep { -e "$_/$sid.lineage.json" } read_dirs();
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
    my ($raw) = grep { defined } map { util::read_file("$_/$sid.lineage.json") } read_dirs();
    return undef unless defined $raw;
    my $j = eval { jsonc::decode($raw) };
    return ref $j eq 'HASH' ? $j : undef;
}

# records_for(sid) -> {n, live => [records with no ended- twin], all => [every live- record],
# newest => record | undef}: the per-process records of one session (file names by sid8, the full
# id checked inside).
sub records_for {
    my ($sid) = @_;
    my $sid8 = substr($sid // '', 0, 8);
    my (%ended, @live, $newest, $newest_t);
    my $n = 0;
    my %seen;
    for my $pf (_pid_files()) {
        my ($fd, $f) = @$pf;
        next unless $f =~ /^(\d+-\d+)\.(live|ended)-\Q$sid8\E\.json$/;
        my ($key, $kind) = ($1, $2);
        next if $seen{$f}++;    # the same record in both roots counts once
        my $raw = util::read_file("$fd/$f") // next;
        my $j = eval { jsonc::decode($raw) };
        next unless ref $j eq 'HASH' && ($j->{session_id} // '') eq $sid;
        $n++;
        if ($kind eq 'ended') { $ended{$key} = 1; next }
        push @live, { %$j, _key => $key };
        my $t = util::parse_iso($j->{ts} // '') // 0;
        ($newest, $newest_t) = ($j, $t) if !defined $newest_t || $t >= $newest_t;
    }
    return { n => $n, live => [grep { !$ended{ $_->{_key} } } @live], all => \@live, newest => $newest };
}

# own_start(sid) -> {since, until, coarse} | undef: from when a row of sid's transcript can be
# sid's own (owner 2026-10-23 xxxxxxxx-27 revised, "No: forks re-ask"). The session's live-
# records (SessionStart writes one before the session writes a row of its own; a launch prompt's
# row may follow it within the same second). Rows that a fork, a `--fork-session` resume or a
# background copy carried over keep the parent's times, all before the first record.
#   - Every record in milliseconds (Time::HiRes present): {since => the earliest, until => the
#     same, coarse => 0}: a row at or after it is own by time.
#   - A record without a fraction (a perl without Time::HiRes, or an older record) names only
#     its second S, and the session may have started anywhere in it: {since => S, until => the
#     next whole second (or an earlier millisecond record), coarse => 1}. A row at or after
#     `until` is own by time; a row in [since, until) is own only by the order rule of
#     transcript::quotes_found (review of bcdaca6): a typed user row that comes after one of this
#     session's SessionStart hook rows (stamped in or after S), with no older row between them.
#     Time alone never makes such a row own, so no clock resolution can let a copy count.
# undef: no record (nothing can be shown to be own).
sub own_start {
    my ($sid) = @_;
    return undef unless defined $sid && !ref $sid && $sid ne '';
    my ($fine, $coarse);
    for my $r (@{ records_for($sid)->{all} || [] }) {
        my $ts = $r->{ts};
        next unless defined $ts && !ref $ts;
        my $e = util::parse_iso($ts) // next;
        if ($ts =~ /T\d\d:\d\d:\d\d\.\d/) { $fine = $e if !defined $fine || $e < $fine }
        else { my $s = int($e); $coarse = $s if !defined $coarse || $s < $coarse }
    }
    return undef unless defined $fine || defined $coarse;
    return { since => $fine, until => $fine, coarse => 0 } if !defined $coarse || (defined $fine && $fine <= $coarse);
    my $until = $coarse + 1;
    $until = $fine if defined $fine && $fine < $until;
    return { since => $coarse, until => $until, coarse => 1 };
}

# own_since(sid) -> epoch | undef: the time from which every row of sid's transcript is own by
# time alone (own_start's `until`).
sub own_since {
    my ($sid) = @_;
    my $s = own_start($sid) or return undef;
    return $s->{until};
}

# first_row(sid_dir, classic stream, mod stream) -> epoch of the session's first record, or undef
# (0.1.4: the one definition core's order canary, reconcile::cutoff, and the watcher's history
# skip, watch::rules::observed_from, both take). Per stream, the first row among its first
# FIRST_ROW_LINES that is not a row a Stop writes itself (OWN_STOP_ROWS: the watcher's sweep,
# sweep_partial, watch_error, precompute_or_failed and core's stop_timing); the earliest of the two
# streams. A session whose streams hold only such rows (the plugin loaded mid-session, its first
# hook a Stop) starts at the earliest of them; one with no row at all at the earliest `ts` of its
# classic-alive.json and mod-alive.json. The streams are append-only, so their first rows never
# change. Pure: reads files only (jsonc, util), no session context.
our @OWN_STOP_ROWS = qw(sweep sweep_partial watch_error precompute_or_failed stop_timing);
our $FIRST_ROW_LINES = 64;
sub first_row {
    my ($sid_dir, @streams) = @_;
    require jsonc;
    require util;
    my %own = map { $_ => 1 } @OWN_STOP_ROWS;
    my ($best, $own);
    for my $p (@streams) {
        next unless defined $p && !ref $p && -f $p && !-l $p;
        open(my $fh, '<:raw', $p) or next;
        my $n = 0;
        while (defined(my $line = <$fh>)) {
            last if ++$n > $FIRST_ROW_LINES;
            (my $raw = $line) =~ s/[\r\n]+\z//;
            my $r = eval { jsonc::decode($raw) };
            next unless ref $r eq 'HASH' && defined $r->{ts} && !ref $r->{ts};
            my $t = util::parse_iso($r->{ts}) // next;
            my $ev = defined $r->{ev} && !ref $r->{ev} ? $r->{ev} : '';
            if ($own{$ev}) { $own = $t if !defined $own || $t < $own; next }
            $best = $t if !defined $best || $t < $best;
            last;
        }
        close $fh;
    }
    return $best // $own if defined $best || defined $own;
    return undef unless defined $sid_dir && !ref $sid_dir;
    my $alive;
    for my $f ("$sid_dir/classic-alive.json", "$sid_dir/mod-alive.json") {
        next unless -f $f && !-l $f;
        my $raw = util::read_file($f);
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        my $e = ref $j eq 'HASH' && defined $j->{ts} && !ref $j->{ts} ? util::parse_iso($j->{ts}) : undef;
        $alive = $e if defined $e && (!defined $alive || $e < $alive);
    }
    return $alive;
}

# record_live(record) -> 1 when a live- record with no ended- twin still counts as live
# (MOD-SPEC §5.8, MOD-SPEC §7 liveness). Owner ruling xxxxxxxx-07 (2026-10-22 23:54, CR-1) on
# question C-STORE-1, "Process gone counts": a record of this host whose pid is gone or runs with
# another start time counts as ended (a crash). A record with no host field (written before
# the host field) or of another host counts as live: only an ended- record ends it (fail
# closed). The literal reading (only an ended- record) is `return 1` here.
sub record_live {
    my ($rec) = @_;
    my $h = $rec->{host};
    return 1 unless defined $h && !ref $h && $h ne '' && $h eq identity::host();
    return identity::alive($rec->{pid}, $rec->{pid_lstart}) ? 1 : 0;
}

# prune_records(now, max) -> the number of per-process records unlinked. lib/plugver.pm runs it
# with the daily load prune, under that prune's lock, on a process's first start. Kept, per
# session id (read from the record; sid8 groups with a single live- record are not read):
#   - the earliest live- record, with milliseconds and without (own_start reads both kinds, so
#     its since and until stay; a resumed session's words typed in an earlier process keep
#     counting), and their ended- twins;
#   - every record of a session whose <watch>/<sid>/pending/ holds a stash (ended() needs a
#     record, else no other session ever finishes it);
#   - every record of a process that may still run: identity::key_live over one
#     identity::start_epochs call (a start that cannot be read counts as running); a record of
#     another host, or with none, counts as running (record_live);
#   - a record that cannot be read, or whose ts cannot.
# Dropped: the other live- records dated over $RECORDS_AGE_S ago, oldest first, at most max files
# a run, each with its ended- twin when that is as old (else the pair stays). Only the effective
# root's folder: a legacy root is never written.
our $RECORDS_AGE_S = 7 * 86400;
sub prune_records {
    my ($now, $max) = @_;
    return 0 unless defined $max && $max > 0;
    my $d = by_pid();
    my (%by8, %names);
    for my $f (util::list_dir($d)) {
        next unless $f =~ /\A(\d+-\d+)\.(live|ended)-([^.\/]+)\.json\z/;
        $names{$f} = 1;
        push @{ $by8{$3} }, [$1, $f] if $2 eq 'live';
    }
    my $host = identity::host();
    my $w = rc::watch();
    my (@cand, %pid);
    for my $s8 (sort grep { @{ $by8{$_} } > 1 } keys %by8) {
        my %sess;
        for my $x (@{ $by8{$s8} }) {
            my $j = eval { jsonc::decode(util::read_file("$d/$x->[1]", 64 * 1024) // '') };
            next unless ref $j eq 'HASH' && defined $j->{session_id} && !ref $j->{session_id};
            my $ts = $j->{ts};
            my $t = defined $ts && !ref $ts ? util::parse_iso($ts) : undef;
            push @{ $sess{ $j->{session_id} } }, { key => $x->[0], name => $x->[1], s8 => $s8, t => $t, host => $j->{host},
                                                   fine => (defined $t && $ts =~ /T\d\d:\d\d:\d\d\.\d/ ? 1 : 0) };
        }
        for my $sid (sort keys %sess) {
            my @r = @{ $sess{$sid} };
            next if @r < 2;
            next if defined $w && args::valid_sid($sid) && orphans::stash_files("$w/$sid");
            my ($ef, $ec);
            for my $r (grep { defined $_->{t} } @r) {
                if ($r->{fine}) { $ef = $r if !$ef || $r->{t} < $ef->{t} }
                else { $ec = $r if !$ec || int($r->{t}) < int($ec->{t}) }
            }
            for my $r (@r) {
                next if ($ef && $r == $ef) || ($ec && $r == $ec);
                next unless defined $r->{t} && $now - $r->{t} > $RECORDS_AGE_S;
                next unless defined $r->{host} && !ref $r->{host} && $r->{host} eq $host;
                push @cand, $r;
                $pid{$1} = 1 if $r->{key} =~ /\A(\d+)-/;
            }
        }
    }
    return 0 unless @cand;
    my $st = identity::start_epochs([sort { $a <=> $b } keys %pid]);
    my $n = 0;
    for my $r (sort { $a->{t} <=> $b->{t} || $a->{name} cmp $b->{name} } @cand) {
        next if identity::key_live($r->{key}, $st);
        my @go = ($r->{name});
        my $tw = "$r->{key}.ended-$r->{s8}.json";
        if ($names{$tw}) {
            my $j = eval { jsonc::decode(util::read_file("$d/$tw", 64 * 1024) // '') };
            my $t = ref $j eq 'HASH' && defined $j->{ts} && !ref $j->{ts} ? util::parse_iso($j->{ts}) : undef;
            next unless defined $t && $now - $t > $RECORDS_AGE_S;
            push @go, $tw;
        }
        last if $n + @go > $max;
        $n += unlink map { "$d/$_" } @go;
    }
    return $n;
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
sub live_peers { return _live(_pid_files()) }

# live_in(by-pid folder) -> the same as live_peers, from one folder's records only (STATE-ROOT
# `migrate`: the sessions that still write in the old handoff root).
sub live_in {
    my ($d) = @_;
    return _live(map { [ $d, $_ ] } util::list_dir($d));
}

sub _live {
    my @pf = @_;
    my %ended;
    my @live;
    for my $pf (@pf) {
        if ($pf->[1] =~ /^(\d+-\d+)\.ended-([^.]+)\.json$/) { $ended{"$1/$2"} = 1; next }
    }
    my %seen;
    for my $pf (@pf) {
        my ($fd, $f) = @$pf;
        next unless $f =~ /^(\d+-\d+)\.live-([^.]+)\.json$/;
        next if $ended{"$1/$2"} || $seen{$f}++;
        my $raw = util::read_file("$fd/$f") // next;
        my $j = eval { jsonc::decode($raw) } or next;
        next unless ref $j eq 'HASH';
        next unless identity::alive($j->{pid}, $j->{pid_lstart});
        push @live, $j;
    }
    return \@live;
}

1;

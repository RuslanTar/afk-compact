package reconcile;
# lib/reconcile.pm: the reconciler at a main turn end (MOD-SPEC §5.4; classic Stop, <= 2 s).
# Owner: WP-core.
#   - P3 scope proof (ROOT-RULINGS F2-1, live probe S-21): the main compact_boundary row
#     is written after PostCompact, so P3 is evaluated here. Each new main boundary row
#     is matched to the PostCompact just before it (a proven main one first); each new
#     subagent boundary row to an unmatched PostCompact before it (a proven subagent one
#     first). A stash PostCompact deferred for want of proof is then saved: main (and
#     swept) when a main row matched it and no subagent row sits beside it, sub when a
#     subagent row did, else unattributed once it is SETTLE_S old and every transcript
#     has been read to its end. Never a main-slot save or a sweep without proof.
#   - a stashed PostCompact or mod summary with no copy -> save it now, `copy_late`
#   - a non-precompute dispatch older than 10 min with no PostCompact and no
#     after-step -> `compaction_unresolved`; a precompute dispatch never followed
#     by an install -> `precompute_not_reused` (counted, never a failure)
#   - order canary C6: a boundary row with no PostCompact, or a PostCompact with no
#     PreCompact and no `precomputed` -> `order_anomaly`
#   - an undelivered main resume block -> `resume_undelivered`
#   - a save that returned EXISTS sha-differs settles its stash once (RRP-04, MOD-SPEC §5.8):
#     `stash_dropped` (redundant) or `stash_kept` (a redacted *.mismatch.md keep)
#   - final mode (SessionEnd, the cross-session finish): no SETTLE_S wait (RRP-05)
#   - the stash index marker <watch>/.orphans/<sid> goes once pending/ holds no stash
# No rule here looks at a stash's age or file time (RRP-05 "no age limit"); SETTLE_S is the
# wait for a boundary row, measured from the PostCompact time in the stash meta.
# Every row is written once (reconcile reads the rows it wrote before).
#
# Persisted incremental state (F2-4): <watch>/<sid>/reconcile.json, written atomically,
# this session's only. It keeps the byte offset of the classic stream, the rollup file,
# the main transcript and each subagent transcript read so far, and what was read from
# them (copies, own rows, PreCompact times, rollup rows, boundary rows with the
# PostCompact each was matched to), so a Stop reads only the bytes that are new. A file
# that was replaced or shortened is read again from its start (rows dedupe by key).
use strict;
use warnings;
use utf8;

our @OWN_ROWS = qw(copy_late compaction_unresolved precompute_not_reused order_anomaly resume_undelivered);
our $STATE = 'reconcile.json';
our $READ_MAX = 32 * 1024 * 1024;   # bytes read from one file per Stop; the rest at the next
our $SETTLE_S = 10;                 # an unproven PostCompact younger than this waits
our $MAIN_WINDOW_S = 600;           # a main boundary row at most this long after its PostCompact
our $SUB_WINDOW_S = 120;            # a subagent boundary row at most this long after its PostCompact
our $TOL_S = 2;                     # subagent rows: slack around a PostCompact's time
# A main boundary row's PostCompact is one at or before the row, never after it (RR-S21-01):
# the row is written after PostCompact and the mod after-step (S-21), and the stash time
# has milliseconds, so a later PostCompact (an unproven subagent one) cannot take its place.

# ---------------------------------------------------------------- state
sub _load {
    my ($sd) = @_;
    my $raw = util::read_file("$sd/$STATE");
    my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
    $j = {} unless ref $j eq 'HASH' && ($j->{v} // 0) == 1;
    $j->{v} = 1;
    for my $k (qw(classic rolls main subs copied logged done mism fill)) { $j->{$k} = {} unless ref $j->{$k} eq 'HASH' }
    for my $k (qw(pre rolls_l bounds sbounds)) { $j->{$k} = [] unless ref $j->{$k} eq 'ARRAY' }
    return $j;
}

sub _save {
    my ($sd, $st) = @_;
    eval { util::write_atomic("$sd/$STATE", jsonc::encode_bytes($st) . "\n", 0600) };
}

# _new_lines(path, fst [, max]) -> (\@complete_lines, read_to_end): the lines past fst->{off}
# (fst = {ino, off}, updated); a new inode or a shorter file starts again at 0.
sub _new_lines {
    my ($path, $fst, $max) = @_;
    $max //= $READ_MAX;
    return ([], 1) unless defined $path && !ref $path && $path ne '' && -f $path;
    my @s = stat(_);
    my $ino = "$s[0]:$s[1]";
    my $size = $s[7];
    if (($fst->{ino} // '') ne $ino || ($fst->{off} // 0) > $size) { $fst->{ino} = $ino; $fst->{off} = 0 }
    my $off = $fst->{off};
    return ([], 1) if $off >= $size;
    open(my $fh, '<:raw', $path) or return ([], 0);
    seek($fh, $off, 0);
    my $want = $size - $off;
    my $to_end = $want <= $max ? 1 : 0;
    $want = $max unless $to_end;
    my $buf = '';
    my $n = read($fh, $buf, $want) // 0;
    close $fh;
    my $nl = rindex($buf, "\n");
    if ($nl < 0) {
        $fst->{off} = $off + $n unless $to_end;    # one line longer than a whole read: step over it
        return ([], $to_end);
    }
    $buf = substr($buf, 0, $nl + 1);
    $fst->{off} = $off + length $buf;
    return ([split /\n/, $buf], $to_end);
}

sub _ingest_classic {
    my ($st, $path) = @_;
    my $alt = join('|', 'copy', 'precompact(?:_shaped|_marker_orphan|_fallback)?', @OWN_ROWS);
    my $want = qr/"ev"\s*:\s*"(?:$alt)"/;
    my ($lines) = _new_lines($path, $st->{classic});
    for my $l (@$lines) {
        next unless $l =~ $want;
        my $r = eval { jsonc::decode($l) };
        next unless ref $r eq 'HASH';
        my $ev = $r->{ev} // '';
        if ($ev eq 'copy') {
            next if ($r->{result} // '') =~ /^failed/;
            # the copy's path under <root> ('' for a mismatch: that copy holds another body)
            my $mism = ($r->{result} // '') eq 'mismatch';
            my $rel = $mism ? '' : ($r->{rel_path} // '');
            $st->{copied}{ $r->{id6} } = $rel if defined $r->{id6};
            $st->{copied}{ 'n:' . $r->{nonce} } = $rel if defined $r->{nonce};
            # the copy a mismatch row names (MOD-SPEC §5.8): a stash still beside it is settled once
            if ($mism && defined $r->{rel_path} && !ref $r->{rel_path}) {
                $st->{mism}{ $r->{id6} } = $r->{rel_path} if defined $r->{id6};
                $st->{mism}{ 'n:' . $r->{nonce} } = $r->{rel_path} if defined $r->{nonce};
            }
        } elsif ($ev =~ /^precompact/) {
            my $e = util::parse_iso($r->{ts} // '');
            push @{ $st->{pre} }, $e if defined $e;
        } else {
            $st->{logged}{ "$ev:" . ($r->{nonce} // $r->{uuid} // $r->{id6} // '') } = 1;
        }
    }
}

sub _ingest_rolls {
    my ($st, $path) = @_;
    my ($lines) = _new_lines($path, $st->{rolls});
    for my $l (@$lines) {
        my $r = eval { jsonc::decode($l) };
        next unless ref $r eq 'HASH';
        push @{ $st->{rolls_l} }, { id6 => $r->{id6}, nonce => $r->{nonce}, e => util::parse_iso($r->{ts} // '') // 0,
                                    actor => $r->{actor}, pc => ($r->{precomputed} ? 1 : 0), join => $r->{join} };
    }
}

# boundary rows of one transcript file into a list (deduped by uuid); -> read_to_end
sub _ingest_bounds {
    my ($fst, $path, $list, $agent) = @_;
    my ($lines, $to_end) = _new_lines($path, $fst);
    my %seen = map { (($_->{u} // '') => 1) } @$list;
    for my $l (@$lines) {
        # An agent file's summary row after a boundary (MOD-SPEC §5.9 step 1): its marker nonce
        # and normalized-body sha only, on the newest boundary of that agent that has none yet
        # (a boundary read in an earlier chunk is carried in the saved state).
        if (defined $agent && (my $sf = transcript::summary_facts($l))) {
            my ($last) = grep { ($_->{a} // '') eq $agent } reverse @$list;
            if ($last && !$last->{s}) { $last->{s} = 1; $last->{n} = $sf->{n}; $last->{h} = $sf->{h} }
            next;
        }
        my $bd = transcript::boundary($l) or next;
        next if defined $bd->{uuid} && $seen{ $bd->{uuid} }++;
        push @$list, { u => $bd->{uuid}, e => $bd->{epoch}, pc => $bd->{precomputed}, pre => $bd->{pre}, post => $bd->{post},
                       ms => $bd->{duration_ms}, (defined $agent ? (a => $agent) : ()), by => undef };
    }
    return $to_end;
}

# ---------------------------------------------------------------- fill (MOD-SPEC §5.9)
# A PostCompact whose copy may be a sub-unknown one: proven sub (P2, or P3 at this reconcile)
# with no agent id from P1.
sub _fill_cand { my ($it) = @_; return !defined $it->{agent} && ($it->{scope} eq 'sub' || ($it->{p3} // '') eq 'sub') ? 1 : 0 }

# A sub-unknown copy in compact/subagents/ gets its agent from a subagent boundary row:
# (a) the row's summary nonce equals the copy's nonce; (b) the row's summary sha equals the
# copy's body sha; (c) time only, when exactly one agent has an unjoined boundary row inside
# the copy's window. Otherwise copy_attribution_ambiguous (once). Only PostCompact copies this
# reconcile has metas for (the pool); a copy already named -a<agent8> is never touched.
sub _fill {
    my ($st, $pool, $n, $subs_end, $left) = @_;
    my $root = rc::root();
    my $logged = $st->{logged};
    my @sb = @{ $st->{sbounds} };
    for my $it (grep { _fill_cand($_) } @$pool) {
        last if !$left->();
        my $id6 = $it->{id6};
        next if $st->{fill}{$id6};
        my $rel = $st->{copied}{$id6};
        next unless defined $rel && $rel ne '';    # not saved yet
        my $path = "$root/$rel";
        my ($csha, $fm) = -f $path ? copies::copy_sha($path) : (undef, undef);
        if (!$fm || ($fm->{actor} // '') ne 'sub-unknown' || $rel !~ m{(?:\A|/)compact/subagents/[^/]+\z} || util::basename($rel) =~ /_[0-9a-z]{8}-a/) {
            $st->{fill}{$id6} = 'n/a';    # not a sub-unknown copy in compact/subagents/
            next;
        }
        my ($bd, $proof);
        my $free = sub { !defined $_[0]{f} };
        if (defined $fm->{nonce} && $fm->{nonce} ne '') { ($bd) = grep { $free->($_) && defined $_->{n} && $_->{n} eq $fm->{nonce} } @sb; $proof = 'a' if $bd }
        if (!$bd && defined $csha) { ($bd) = grep { $free->($_) && defined $_->{h} && $_->{h} eq $csha } @sb; $proof = 'b' if $bd }
        if (!$bd) {
            next unless $subs_end;    # an agent file not read to its end may still hold the row
            # candidates: every agent with a free boundary row within SUB_WINDOW_S on either side
            # (the stricter count, core-escalations E-C9-10); a fill only when there is exactly
            # one, and its row lies in the P3 window [e - TOL_S, e + SUB_WINDOW_S]
            my @near = grep { $free->($_) && defined $_->{a} && abs($_->{e} - $it->{e}) <= $SUB_WINDOW_S } @sb;
            my @in = grep { $_->{e} >= $it->{e} - $TOL_S } @near;
            my %ag = map { ($_->{a} => 1) } @near;
            if (keys %ag == 1 && @in) { ($bd) = sort { $a->{e} <=> $b->{e} } @in; $proof = 'c' }
            elsif (keys %ag > 1) {
                $st->{fill}{$id6} = 'ambiguous';
                next if $logged->{"copy_attribution_ambiguous:$id6"}++;
                rc::emit('copy_attribution_ambiguous', [id6 => $id6, candidates => [sort keys %ag]]);
                next;
            }
            else { next }
        }
        my $r = copies::attribute(path => $path, agent => $bd->{a}, proof => $proof);
        if (!$r->{ok}) {
            $st->{fill}{$id6} = 'failed';
            rc::emit('copy_attribution_failed', [id6 => $id6, why => $r->{why}]);
            next;
        }
        $bd->{f} = $id6;
        $st->{fill}{$id6} = 'done';
        $st->{copied}{$id6} = $r->{rel};
        $st->{copied}{ 'n:' . $fm->{nonce} } = $r->{rel} if defined $fm->{nonce} && $fm->{nonce} ne '';
        rc::emit('copy_attributed', [id6 => $id6, nonce => $fm->{nonce}, from_rel => $rel, rel_path => $r->{rel}, actor => $bd->{a},
                                     proof => $proof, seq => $r->{seq}, pre_tokens => $bd->{pre}, post_tokens => $bd->{post}]);
        $n->{attributed}++;
    }
}

# PostCompacts not yet done: their .post.json metas (content-free), oldest first
sub _pool {
    my ($sd, $st) = @_;
    my @pool;
    for my $f (util::list_dir("$sd/pending")) {
        next unless $f =~ /^([0-9a-f]{6}|h[0-9a-f]{5}(?:-\d+)?)\.post\.json$/;
        my $id6 = $1;
        next if $st->{done}{$id6};
        my $raw = util::read_file("$sd/pending/$f") // next;
        my $m = eval { jsonc::decode($raw) };
        next unless ref $m eq 'HASH';
        my $e = util::parse_iso($m->{ts} // '') // next;
        push @pool, { %$m, id6 => $id6, e => $e, scope => ($m->{scope} // 'unknown'),
                      scope_deferred => ($m->{scope_deferred} ? 1 : 0), stale => ($m->{stale} ? 1 : 0) };
    }
    return [sort { $a->{e} <=> $b->{e} || $a->{id6} cmp $b->{id6} } @pool];
}

# ---------------------------------------------------------------- P3 (F2-1)
# Match boundary rows to PostCompacts; sets $it->{mb} (main row) / $it->{sb} (subagent row)
# and $it->{p3} = main | sub | undef for each pool item.
sub _match {
    my ($st, $pool) = @_;
    my %by = map { ($_->{id6} => $_) } @$pool;
    for my $bd (@{ $st->{bounds} }) { my $it = defined $bd->{by} ? $by{ $bd->{by} } : undef; $it->{mb} = $bd if $it }
    for my $bd (@{ $st->{sbounds} }) { my $it = defined $bd->{by} ? $by{ $bd->{by} } : undef; $it->{sb} = $bd if $it }
    for my $bd (sort { $a->{e} <=> $b->{e} } grep { !defined $_->{by} } @{ $st->{bounds} }) {
        my @c = grep { !$_->{mb} && !$_->{sb} && $_->{scope} ne 'sub'
                       && $_->{e} <= $bd->{e} && $bd->{e} - $_->{e} <= $MAIN_WINDOW_S } @$pool;
        my @proven = grep { $_->{scope} eq 'main' } @c;
        my ($it) = sort { $b->{e} <=> $a->{e} } (@proven ? @proven : @c);
        next unless $it;
        $it->{mb} = $bd;
        $bd->{by} = $it->{id6};
    }
    my @sb = sort { $a->{e} <=> $b->{e} } grep { !defined $_->{by} } @{ $st->{sbounds} };
    for my $pass ('sub', 'unknown') {
        for my $it (grep { !$_->{mb} && !$_->{sb} && $_->{scope} eq $pass } @$pool) {
            my ($sbd) = grep { !defined $_->{by} && $_->{e} >= $it->{e} - $TOL_S && $_->{e} - $it->{e} <= $SUB_WINDOW_S
                               && (!defined $it->{agent} || ($_->{a} // '') eq $it->{agent}) } @sb;
            next unless $sbd;
            $it->{sb} = $sbd;
            $sbd->{by} = $it->{id6};
        }
    }
    for my $it (@$pool) {
        if ($it->{sb}) { $it->{p3} = 'sub'; next }
        next unless $it->{mb};
        # main = P3-main with no subagent signal (MOD-SPEC §2.4): a subagent row beside it -> both
        my $beside = grep { !defined $_->{by} && $_->{e} >= $it->{e} - $TOL_S && $_->{e} <= $it->{e} + $TOL_S + 5 } @sb;
        $it->{p3} = $beside ? undef : 'main';
    }
}

# ---------------------------------------------------------------- run
# run(transcript => P, cwd => C, budget_ms => 2000, cutoff => epoch, final => 0|1)
#   -> {late, unresolved, precompute_not_reused, order_anomaly, undelivered, saved, kept, dropped}
# final (MOD-SPEC §5.4 "Final mode": SessionEnd, and the cross-session finish): P3 first, then
# every stash still unproven once the transcripts are read to their end is saved as
# unattributed at once (the SETTLE_S wait is waived); a stash whose transcripts were not
# read to their end within the budget stays for the next run.
sub run {
    my (%a) = @_;
    my $sid_dir = rc::sid_dir() // return {};
    my $n = _counts();
    # one reconciler per session at a time (a Stop and a `reconcile` call may meet)
    my $out = eval {
        lock::with("$sid_dir/reconcile.lock", { sid => rc::sid(), actor => 'reconcile' }, sub { _run(\%a, $n, $sid_dir) }, wait_ms => 300);
    };
    return $out // $n;
}

# run_locked(...): the same run for a caller that already holds this session's
# reconcile.lock (the cross-session finish, lib/orphans.pm, in the ended session's context).
sub run_locked {
    my (%a) = @_;
    my $sid_dir = rc::sid_dir() // return {};
    my $n = _counts();
    my $out = eval { _run(\%a, $n, $sid_dir) };
    return $out // $n;
}

sub _counts { return { map { ($_ => 0) } qw(late unresolved precompute_not_reused order_anomaly undelivered saved kept dropped attributed) } }

# A save that returned EXISTS sha-differs: the stash is settled once (RRP-04, MOD-SPEC §5.8).
sub _settle {
    my ($n, $path, $save, $scan) = @_;
    my $r = copies::settle_mismatch(path => $path, save => $save, scan => $scan) // return;
    $n->{$r eq 'kept' ? 'kept' : 'dropped'}++;
}

sub _run {
    my ($args, $n, $sid_dir) = @_;
    my %a = %$args;
    # test seam: a small read limit stands in for a transcript over READ_MAX (AT-ST-03 c)
    local $READ_MAX = (util::test_mode() && ($ENV{STORE_TEST_READ_MAX} // '') =~ /\A\d+\z/) ? 0 + $ENV{STORE_TEST_READ_MAX} : $READ_MAX;
    my $sid = rc::sid();
    my $watch = rc::watch();
    my $t0 = util::clock_ms();
    my $deadline = $t0 + ($a{budget_ms} // 2000);
    my $left = sub { my $l = $deadline - util::clock_ms(); return $l > 0 ? $l : 0 };
    my $now = util::now();
    my $st = _load($sid_dir);

    # only what is new since the last Stop (F2-4)
    _ingest_classic($st, rc::stream_path('classic'));
    _ingest_rolls($st, "$sid_dir/compactions.jsonl");
    my $tp = $a{transcript};
    my $main_end = 1;
    if (defined $tp && !ref $tp && $tp ne '') {
        $st->{main} = { path => $tp } if ($st->{main}{path} // '') ne $tp;
        $main_end = _ingest_bounds($st->{main}, $tp, $st->{bounds});
    }
    my $copied = $st->{copied};
    my $logged = $st->{logged};
    my @disp = dispatch::all($watch, $sid);
    my %disp = map { ($_->{nonce} => $_) } @disp;
    my $root_ok = rc::root_ok('handoff_root');

    # A stash whose summary a copy already holds (same normalized body) is dropped (F2-7).
    # A copy row that said mismatch (rel '') leaves the stash to be settled once (§5.8).
    my $drop_if_held = sub {
        my ($f, $rel, $text) = @_;
        return unless defined $text;
        if (!defined $rel || $rel eq '') {
            my ($stem) = $f =~ /\A(.+)\.(?:post|mod)\.md\z/ or return;
            my $mrel = $st->{mism}{$stem} // $st->{mism}{ substr($stem, 0, 6) } // $st->{mism}{"n:$stem"};
            return unless defined $mrel;
            my $s = detect::scan($text);
            _settle($n, "$sid_dir/pending/$f", { result => 'mismatch', path => rc::root() . "/$mrel", rel => $mrel,
                                                 verdict => detect::verdict($s) }, $s);
            return;
        }
        my ($csha) = copies::copy_sha(rc::root() . "/$rel");
        copies::drop_stash("$sid_dir/pending/$f", 'exists')
            if defined $csha && $csha eq sha::hex256(detect::scan($text)->{normalized});
    };
    my $held = sub {
        my ($it) = @_;
        for my $k ($it->{id6}, (defined $it->{nonce} ? 'n:' . $it->{nonce} : ())) { return $copied->{$k} if exists $copied->{$k} }
        return undef;
    };

    # 0. P3 for the PostCompacts not yet done
    my $pool = _pool($sid_dir, $st);
    my $subs_end = 1;
    if (grep { (!$_->{sb} && $_->{scope} ne 'main') || (_fill_cand($_) && !$st->{fill}{ $_->{id6} }) } @$pool) {
        for my $f (@{ transcript::subagent_files($tp, $sid) }) {
            my $fst = ($st->{subs}{ $f->{path} } ||= {});
            $subs_end = 0 unless _ingest_bounds($fst, $f->{path}, $st->{sbounds}, $f->{agent_id});
        }
    }
    _match($st, $pool);
    my %p3 = map { ($_->{id6} => $_) } grep { $_->{p3} } @$pool;
    for my $it (grep { $_->{scope_deferred} } @$pool) {
        last if !$left->();
        next unless $root_ok;
        my $f = "$it->{id6}.post.md";
        my $text = util::read_file("$sid_dir/pending/$f");
        my $rel = $held->($it);
        if (defined $rel) { $drop_if_held->($f, $rel, $text); next }
        next unless defined $text;
        my ($scope, $agent, $proof);
        if (($it->{p3} // '') eq 'main') { ($scope, $proof) = ('main', 'p3-main') }
        # P3-sub: the agent only from P1 (the meta); a time match names no agent: the copy is
        # sub-unknown and the fill below decides (MOD-SPEC §5.3 step 3, §5.9)
        elsif (($it->{p3} // '') eq 'sub') { ($scope, $agent, $proof) = ('sub', $it->{agent}, 'p3-sub') }
        elsif ($main_end && $subs_end && ($a{final} || $now - $it->{e} >= $SETTLE_S)) { ($scope, $proof) = ('unknown', 'none') }
        else { next }    # its boundary row may still come: the next Stop decides
        _save_deferred($it, $text, $scope, $agent, $proof, \%a, $left, $copied, $f, $n);
    }

    # 1. stashes without a copy. Not while handoff_root is refused (MOD-SPEC §1.2): every
    # save would be refused again and log another failed copy row at each Stop; the
    # stashes wait for a later Stop with a safe root (the refusal row is once per session).
    my @pending = $root_ok ? util::list_dir("$sid_dir/pending") : ();
    for my $f (@pending) {
        last if !$left->();
        my ($id6, $kind, $nonce);
        if ($f =~ /^([0-9a-f]{6}|h[0-9a-f]{5}(?:-\d+)?)\.post\.md$/) { ($id6, $kind) = ($1, 'post') }
        elsif ($f =~ /^([0-9a-f]{8})\.mod\.md$/) { ($nonce, $kind) = ($1, 'mod'); $id6 = substr($1, 0, 6) }
        else { next }
        my $text = util::read_file("$sid_dir/pending/$f") // next;
        if (exists $copied->{$id6} || (defined $nonce && exists $copied->{"n:$nonce"})) {
            $drop_if_held->($f, (exists $copied->{$id6} ? $copied->{$id6} : $copied->{"n:$nonce"}), $text);
            next;
        }
        my %m;
        if ($kind eq 'post') {
            my $raw = util::read_file("$sid_dir/pending/$id6.post.json");
            my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
            %m = %$j if ref $j eq 'HASH';
            next if $m{scope_deferred};    # step 0's: saved once P3 decides
            # a deferred unmarked summary: the after-step's nonce, if it ever saved, is copied under it
            if (!defined $m{nonce} && defined $m{deferred} && exists $copied->{"n:$m{deferred}"}) {
                $drop_if_held->($f, $copied->{"n:$m{deferred}"}, $text);
                next;
            }
        }
        my $s = detect::scan($text);
        my $mn = $nonce // $m{nonce} // ($m{stale} ? undef : $s->{nonce});
        # P1 (MOD-SPEC §2.4): the record of the nonce in the mod stash name or the summary marker
        my $p1 = defined $mn ? $disp{$mn} : undef;
        my $drec = $p1 // (defined $m{deferred} ? $disp{ $m{deferred} } : undef);
        # a deferred stash is named under its pending mod dispatch (as the after-step would
        # save it), but that dispatch is no scope proof: the scope is the stash's own, or P3's
        if (!defined $mn && $drec && dispatch::is_mod($drec)) { $mn = $drec->{nonce} }
        my $scope = $m{scope} // 'unknown';
        my $agent = $m{agent};
        if ($scope eq 'unknown' && $p3{$id6}) {
            $scope = $p3{$id6}{p3};
        }
        if ($p1 && dispatch::is_mod($p1)) { $scope = defined $p1->{agent_id} ? 'sub' : 'main' }
        $agent //= $p1->{agent_id} if $p1;
        # unproven: its boundary row may still come; wait as step 0 does
        if ($scope eq 'unknown' && $kind eq 'post') {
            my $e = util::parse_iso($m{ts} // '') // 0;
            next unless $main_end && $subs_end && ($a{final} || $now - $e >= $SETTLE_S);
        }
        if (defined $mn && exists $copied->{"n:$mn"}) { $drop_if_held->($f, $copied->{"n:$mn"}, $text); next }
        my $save = copies::save(sid => $sid, text => $text, scan => $s, nonce => $mn, content_name => ($m{stale} ? 1 : 0),
                                writer => ($kind eq 'mod' ? 'mod' : 'postcompact-fallback'),
                                scope => $scope, agent => $agent, tokens => $m{tokens}, cwd => $m{cwd} // $a{cwd},
                                transcript => $m{transcript} // $a{transcript}, trigger => ($drec ? $drec->{trigger} : $m{trigger}),
                                dispatch => $drec, channel => ($drec ? $drec->{channel} : 'none'),
                                precomputed => $m{precomputed}, late => 1,
                                verdict_ctx => { dispatch_nonce => ($drec ? $drec->{nonce} : undef), ($m{stale} ? (marker_earlier => 1) : ()) });
        copies::drop_stash("$sid_dir/pending/$f", $save->{result}) if $save->{exit} == 0;
        _settle($n, "$sid_dir/pending/$f", $save, $s) if $save->{exit} == 0;
        next unless $save->{exit} == 0 && $save->{result} eq 'late';
        $n->{late}++;
        $n->{saved}++;
        $copied->{ $save->{id6} } = $save->{rel};
        $copied->{"n:$mn"} = $save->{rel} if defined $mn;
        rc::emit('copy_late', [nonce => $mn, id6 => $save->{id6}, rel_path => $save->{rel}]);
        $logged->{"copy_late:" . ($mn // $save->{id6})} = 1;
        # Main-proven: sweep (MOD-SPEC §5.3 step 5), as step 0 does (RR-S21-04). The
        # swept/<id6> claim (the nonce's first 6, as the mod's after-step claims it) keeps a
        # compaction from being swept twice.
        my $sweep;
        if ($scope eq 'main') {
            (my $stem = util::basename($save->{path} // '')) =~ s/\.md$//;
            $sweep = sweep::run(sid => $sid, id6 => $save->{id6}, stem => $stem, transcript => $m{transcript} // $a{transcript},
                                budget_ms => $left->(), bucket => ($save->{bucket} ? $save->{bucket}{path} : undef), nonce => $mn);
        }
        my $tot = $sweep ? $sweep->{totals} : undef;
        my $rolled = grep { (($_->{id6} // '') eq $id6) || (defined $mn && ($_->{nonce} // '') eq $mn) } @{ $st->{rolls_l} };
        if (!$rolled) {
            my $actor = $scope eq 'main' ? 'main' : $scope eq 'sub' ? ($agent // 'sub-unknown') : 'unattributed';
            rollup::write(session_id => $sid, actor => $actor,
                          compaction_seq => $save->{seq}, nonce => $mn, id6 => $save->{id6}, join => 'reconcile',
                          trigger => ($drec ? $drec->{trigger} : $m{trigger}), idle => 'unknown',
                          channel => ($drec ? $drec->{channel} : 'none'), seat_state => ($drec ? (postcompact::seat_state($drec, $a{transcript}))[0] : 'none'),
                          verdict => $save->{verdict}, verdict_source => ($kind eq 'mod' ? 'after-step' : 'postcompact'),
                          marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end},
                          sentinel_place => $s->{sentinel_place},
                          summary_chars => $s->{chars}, shape_class => detect::shape_class($s),
                          copy => 'late', copy_path => $save->{rel},
                          resume => rollup::resume_state($sid_dir, $mn, $scope, ($drec ? $drec->{channel} : "none")),
                          evidence => ($tot ? { copied => $tot->{copied}, dup => $tot->{dup}, ref_only => $tot->{'ref-only'},
                                                redacted => $tot->{redacted}, withheld => $tot->{withheld} } : undef));
            push @{ $st->{rolls_l} }, { id6 => $save->{id6}, nonce => $mn, e => $now, actor => $actor, pc => 0, join => 'reconcile' };
        }
    }

    # fill: sub-unknown copies get their agent (MOD-SPEC §5.9)
    _fill($st, $pool, $n, $subs_end, $left) if $root_ok && $left->();

    # done: a PostCompact whose summary is copied and whose rows are matched (or too old to be);
    # a sub-unknown copy also waits for its fill decision
    for my $it (@$pool) {
        my $has = defined $held->($it) || !-e "$sid_dir/pending/$it->{id6}.post.md";
        my $fill_open = _fill_cand($it) && !$st->{fill}{ $it->{id6} } && $now - $it->{e} <= $MAIN_WINDOW_S;
        $st->{done}{ $it->{id6} } = 1 if $has && !$fill_open && ($it->{mb} || $it->{sb} || $now - $it->{e} > $MAIN_WINDOW_S);
    }

    my $in_time = $left->() > 0;
    my $cutoff = $a{cutoff};
    # 2. unresolved and precompute dispatches (> 10 min old)
    if ($in_time) {
        my %post;
        for my $it (@$pool) { $post{$_} = 1 for grep { defined } @$it{qw(nonce dispatch deferred)} }
        for my $d (@disp) {
            last if !$left->();
            next unless $d->{_epoch} && $now - $d->{_epoch} > 600 && $now - $d->{_epoch} < 7 * 86400;
            my $nn = $d->{nonce};
            if (($d->{trigger} // '') eq 'precompute') {
                next if $logged->{"precompute_not_reused:$nn"};
                next if grep { $_->{pc} && $_->{e} >= $d->{_epoch} } @{ $st->{bounds} };
                rc::emit('precompute_not_reused', [nonce => $nn]);
                $logged->{"precompute_not_reused:$nn"} = 1;
                $n->{precompute_not_reused}++;
                next;
            }
            next if $logged->{"compaction_unresolved:$nn"} || exists $copied->{"n:$nn"} || $post{$nn};
            next if grep { ($_->{nonce} // '') eq $nn } @{ $st->{rolls_l} };
            next if -e "$sid_dir/pending/$nn.mod.md";
            rc::emit('compaction_unresolved', [nonce => $nn, trigger => $d->{trigger}, channel => $d->{channel}]);
            $logged->{"compaction_unresolved:$nn"} = 1;
            $n->{unresolved}++;
        }
    }

    # 3. order canary C6 (only for rows after this session's first record)
    if (defined $cutoff && $left->()) {
        for my $bd (grep { !defined $_->{by} } @{ $st->{bounds} }) {
            next unless $bd->{e} >= $cutoff && $now - $bd->{e} > 15;
            my $key = "order_anomaly:" . ($bd->{u} // '');
            next if $logged->{$key};
            # a rollup row near it also counts as its PostCompact (rows from before the metas)
            next if grep { abs($_->{e} - $bd->{e}) <= 120 } @{ $st->{rolls_l} };
            rc::emit('order_anomaly', [uuid => $bd->{u}, kind => 'boundary-without-postcompact']);
            $logged->{$key} = 1;
            $bd->{by} = '-';
            $n->{order_anomaly}++;
        }
        for my $r (grep { !$_->{ck} } @{ $st->{rolls_l} }) {
            next if $r->{pc} || ($r->{join} // '') eq 'reconcile' || $r->{e} < $cutoff;
            my $key = "order_anomaly:" . ($r->{id6} // '');
            $r->{ck} = 1;
            next if $logged->{$key};
            next if grep { $_ <= $r->{e} + 1 && $_ >= $r->{e} - 900 } @{ $st->{pre} };
            rc::emit('order_anomaly', [id6 => $r->{id6}, nonce => $r->{nonce}, kind => 'postcompact-without-precompact']);
            $logged->{$key} = 1;
            $n->{order_anomaly}++;
        }
    }

    # 4. undelivered main resume blocks
    for my $r (grep { !$_->{rd} } @{ $st->{rolls_l} }) {
        next unless ($r->{actor} // '') eq 'main' && defined $r->{nonce};
        next unless $now - $r->{e} > 30;
        $r->{rd} = 1;
        next if -e "$sid_dir/resume-claimed/$r->{nonce}" || $logged->{"resume_undelivered:$r->{nonce}"};
        rc::emit('resume_undelivered', [nonce => $r->{nonce}]);
        $logged->{"resume_undelivered:$r->{nonce}"} = 1;
        $n->{undelivered}++;
    }

    # boundaries.count: the main boundary rows accounted for (matched, or flagged)
    my $acc = grep { defined $_->{by} } @{ $st->{bounds} };
    if ($acc != scope::stored_count($sid_dir)) { eval { scope::set_count($sid_dir, $acc, { sid => $sid, actor => 'main' }) } }
    _save($sid_dir, $st);
    # the stash index: this session's marker goes once pending/ holds no stash (§5.8)
    orphans::unmark($sid, $sid_dir);
    return $n;
}

# Save a stash PostCompact deferred for want of scope proof, as P3 decided (F2-1).
sub _save_deferred {
    my ($it, $text, $scope, $agent, $proof, $args, $left, $copied, $f, $n) = @_;
    my $sid = rc::sid();
    my $sid_dir = rc::sid_dir();
    my $s = detect::scan($text);
    my $mn = $it->{stale} ? undef : $it->{nonce};
    my $drec = defined $it->{dispatch} ? dispatch::read(rc::watch(), $sid, $it->{dispatch}) : undef;
    my $rec = defined $s->{nonce} ? dispatch::read(rc::watch(), $sid, $s->{nonce}) : undef;
    my $mb = $it->{mb};
    my $precomputed = ($mb && $mb->{pc}) || $it->{precomputed} ? 1 : 0;
    my $tokens = $mb ? [$mb->{pre}, $mb->{post}] : $it->{tokens};
    my %vc = (precomputed => $precomputed, scope => $scope);
    if (defined $s->{nonce}) { $vc{marker_has_record} = $rec ? 1 : 0; $vc{marker_earlier} = 1 if $it->{stale} }
    my $verdict = detect::verdict($s, %vc);
    my ($seat, $esc) = postcompact::seat_state($drec, $it->{transcript} // $args->{transcript});
    my $channel = $drec ? $drec->{channel} : 'none';
    my $trigger = postcompact::_trigger($drec, $it->{trigger});
    my $save = copies::save(sid => $sid, text => $text, scan => $s, nonce => $mn, content_name => $it->{stale},
                            writer => 'postcompact-fallback', scope => $scope, agent => $agent, tokens => $tokens,
                            cwd => $it->{cwd} // $args->{cwd}, transcript => $it->{transcript} // $args->{transcript},
                            trigger => $trigger, dispatch => ($mn && $rec ? $rec : undef), seat_state => $seat, channel => $channel,
                            precomputed => $precomputed, verdict => $verdict, proof => $proof);
    return unless $save->{exit} == 0;
    copies::drop_stash("$sid_dir/pending/$f", $save->{result});
    _settle($n, "$sid_dir/pending/$f", $save, $s) if $n;
    $n->{saved}++ if $n && $save->{result} =~ /\A(?:saved|unattributed|late)\z/;
    # Final mode saved it without the settle wait: the session ended first (AT-ST-03 b)
    if ($args->{final} && $save->{result} =~ /\A(?:saved|unattributed)\z/) {
        rc::emit('copy_late', [nonce => $mn, id6 => $save->{id6}, rel_path => $save->{rel}]);
        $n->{late}++ if $n;
    }
    $copied->{ $it->{id6} } = $save->{rel};
    $copied->{"n:$mn"} = $save->{rel} if defined $mn;
    my $sweep;
    if ($scope eq 'main') {
        (my $stem = util::basename($save->{path} // '')) =~ s/\.md$//;
        $sweep = sweep::run(sid => $sid, id6 => $it->{id6}, stem => $stem, transcript => $it->{transcript} // $args->{transcript},
                            budget_ms => $left->(), bucket => ($save->{bucket} ? $save->{bucket}{path} : undef), nonce => $mn);
    }
    my $nonce = $drec ? $drec->{nonce} : $mn;
    my $tot = $sweep ? $sweep->{totals} : undef;
    my $measured = $drec && grep { $_ eq 'measured' } @{ $drec->{tags} || [] };
    my $actor = $scope eq 'main' ? 'main' : $scope eq 'sub' ? ($agent // 'sub-unknown') : 'unattributed';
    rollup::write(
        ts => util::iso($it->{e}), session_id => $sid, actor => $actor, compaction_seq => $save->{seq},
        nonce => $nonce, id6 => $it->{id6}, join => $it->{join}, trigger => $trigger,
        midturn => ($drec ? $drec->{midturn} : undef), idle => 'unknown', channel => $channel, seat_state => $seat,
        verdict => $verdict, verdict_source => 'postcompact', marker_line => $s->{marker_line},
        sentinel_from_end => $s->{sentinel_from_end}, sentinel_place => $s->{sentinel_place},
        fabricated_check_tokens => ($measured ? 0 : detect::fabricated_check_tokens($s->{normalized})),
        instructions_bytes => ($drec ? $drec->{instructions_bytes} : undef), summary_chars => $s->{chars},
        shape_class => detect::shape_class($s), pre_tokens => ($mb ? $mb->{pre} : undef),
        post_tokens => ($mb ? $mb->{post} : undef), duration_ms => ($mb ? $mb->{ms} : undef),
        precomputed => jsonc::bool($precomputed), copy => $save->{result}, copy_path => $save->{rel},
        resume => rollup::resume_state($sid_dir, $nonce, $scope, $channel),
        checkpoint_ms => undef,
        evidence => ($tot ? { copied => $tot->{copied}, dup => $tot->{dup}, ref_only => $tot->{'ref-only'},
                              redacted => $tot->{redacted}, withheld => $tot->{withheld} } : undef),
        nudged => undef, continued => undef, halt => undef);
    rc::emit('scope_leak', [nonce => $s->{nonce}, scope => $scope, marker_scope => $s->{scope}]) if $verdict eq 'scope-leak';
}

# The order canary looks only at boundaries after this session's first record.
sub cutoff {
    my $d = rc::sid_dir() // return undef;
    my @t;
    for my $f (rc::stream_path('classic'), "$d/classic-alive.json", "$d/mod-alive.json") {
        next unless defined $f && -e $f;
        if ($f =~ /\.jsonl$/) {
            open(my $fh, '<:raw', $f) or next;
            my $first = <$fh>;
            close $fh;
            my $j = defined $first ? eval { jsonc::decode($first) } : undef;
            my $e = ref $j eq 'HASH' ? util::parse_iso($j->{ts} // '') : undef;
            push @t, $e if defined $e;
        } else {
            my $raw = util::read_file($f);
            my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
            my $e = ref $j eq 'HASH' ? util::parse_iso($j->{ts} // '') : undef;
            push @t, $e if defined $e;
        }
    }
    my ($min) = sort { $a <=> $b } @t;
    return $min;
}


sub line {
    my ($n) = @_;
    return sprintf('reconciled late=%d unresolved=%d precompute_not_reused=%d order_anomaly=%d undelivered=%d',
                   map { $n->{$_} // 0 } qw(late unresolved precompute_not_reused order_anomaly undelivered));
}

1;

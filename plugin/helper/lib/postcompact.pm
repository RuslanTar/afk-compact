package postcompact;
# lib/postcompact.pm: classic PostCompact, the primary saver (MOD-SPEC §5.3 steps 1-6, as
# ROOT-RULINGS F2-1 and F2-2 order them). Owner: WP-core. Steps: stash; nonce from the
# marker (a stale marker counts as none); dispatch lookup; scope proof from P1/P2 only
# (the main compact_boundary row is written after this hook, S-21); defer rules
# (copy_deferred: to the mod's after-step, or to reconcile when nothing proves the
# scope); save-copy --writer postcompact-fallback (secret scan inside); main-proven
# sweep (8 s budget); rollup, verdict and escalation rows. Returns the detector run for
# watch.on_hook.
use strict;
use warnings;

sub _resolved {
    my ($sid_dir, $classic) = @_;
    my %r;
    for my $row (@{ rollup::rows($sid_dir) }) { $r{ $row->{nonce} } = 1 if defined $row->{nonce} }
    for my $row (@{ rollup::stream_rows($classic, evs => [qw(copy copy_deferred)]) }) {
        next unless ($row->{ev} // '') =~ /^(copy|copy_deferred)$/ && defined $row->{nonce};
        next if ($row->{ev} eq 'copy') && ($row->{result} // '') =~ /^failed/;
        $r{ $row->{nonce} } = 1;
    }
    return \%r;
}

# Nonces of mod dispatches that will get no after-step: the mod logged the
# $.session.compact call as rejected, or the compaction as skipped (compacted skip=<class>).
sub _mod_closed {
    my %c;
    for my $row (@{ rollup::stream_rows(rc::stream_path('mod'), evs => [qw(compact_rejected compacted)]) }) {
        my $ev = $row->{ev} // '';
        next unless defined $row->{nonce} && !ref $row->{nonce};
        $c{ $row->{nonce} } = 1 if $ev eq 'compact_rejected' || ($ev eq 'compacted' && defined $row->{skip});
    }
    return \%c;
}

sub seat_state {
    my ($drec, $transcript) = @_;
    return ('none', undef) unless $drec;
    my $ch = $drec->{channel} // '';
    return ('mod-hook', undef) if $ch eq 'mod-hook';
    return ('mod-self', undef) if $ch eq 'mod-self';
    my $sid_dir = rc::sid_dir();
    my $raw = defined $sid_dir ? util::read_file("$sid_dir/mod-alive.json") : undef;
    my $alive = defined $raw ? eval { jsonc::decode($raw) } : undef;
    my $c = rc::claude();
    if (ref $alive eq 'HASH' && defined $alive->{pid} && $alive->{pid} == ($c->{pid} // -1)
        && (!defined $alive->{pid_lstart} || !defined $c->{lstart} || $alive->{pid_lstart} eq $c->{lstart})) {
        my $turn = transcript::last_prompt_epoch($transcript);
        my $ats = util::parse_iso($alive->{ts} // '');
        if (!defined $turn || (defined $ats && $ats >= $turn - 2)) { return ('classic-only', 'bypass_suspected') }
    }
    return ('classic-only', 'mod_off');
}

sub _trigger {
    my ($drec, $payload_trigger) = @_;
    my $t = $payload_trigger;
    $t = 'unknown' unless defined $t && $t =~ /^(manual|auto)$/;
    return $t unless $drec;
    return 'plugin' if ($drec->{channel} // '') eq 'mod-self';
    return $drec->{trigger} // $t if ($drec->{channel} // '') eq 'mod-hook';
    return $t;
}

# F2-2 (SPEC-03): does the summary repeat the marker of an earlier compaction of this
# session? Yes when that marker's copy, or its unsaved stash, holds another body. Such a
# summary is saved under a content name (h<sha5>), verdict stale, never lost.
sub stale_marker {
    my (%a) = @_;
    my ($mn, $sha, $sid, $sid_dir) = @a{qw(nonce sha sid sid_dir)};
    return 0 unless defined $mn;
    my $st = util::read_file("$sid_dir/pending/" . substr($mn, 0, 6) . '.post.md');
    if (defined $st) { return sha::hex256(detect::scan($st)->{normalized}) ne $sha ? 1 : 0 }
    return 0 unless $a{dispatch} && $a{resolved}{$mn};
    my $bk = bucket::resolve($sid, $a{cwd});
    my $ex = copies::find($bk->{path}, substr($mn, 0, 6)) // return 0;
    my ($esha, $efm) = copies::copy_sha($ex);
    return (defined $esha && ($efm->{session_id} // '') eq $sid && ($efm->{nonce} // '') eq $mn && $esha ne $sha) ? 1 : 0;
}

# The boundary row of this compaction, when it is already written (S-21: usually not):
# only a row no older than this compaction's dispatch can be told apart from an earlier
# compaction's row, so without a dispatch there is none. Read from the transcript tail.
sub own_boundary {
    my (%a) = @_;
    my $d = $a{dispatch} // return undef;
    my $since = $d->{_epoch} // util::parse_iso($d->{ts} // '') // return undef;
    my @b;
    if ($a{scope} eq 'main') {
        @b = @{ transcript::boundaries($a{transcript}, tail => 8 * 1024 * 1024) };
    } elsif ($a{scope} eq 'sub') {
        for my $f (@{ transcript::subagent_files($a{transcript}, $a{sid}) }) {
            next if defined $a{agent} && $f->{agent_id} ne $a{agent};
            push @b, @{ transcript::boundaries($f->{path}, tail => 8 * 1024 * 1024) };
        }
    }
    my ($b) = sort { $b->{epoch} <=> $a->{epoch} } grep { $_->{epoch} >= $since - 1 } @b;
    return $b;
}

sub run {
    my ($p) = @_;
    my $sid = rc::sid();
    my $sid_dir = rc::sid_dir() // return;
    my $watch = rc::watch();
    my $text = $p->{compact_summary};
    $text = '' unless defined $text && !ref $text;
    my $tp = $p->{transcript_path};
    my $cwd = $p->{cwd};
    my $now = util::now();
    my $s = detect::scan($text);
    $s->{sha256} = sha::hex256($s->{normalized});
    my $mn = $s->{nonce};
    my $rec = defined $mn ? dispatch::read($watch, $sid, $mn) : undef;
    my @all = dispatch::all($watch, $sid);
    my $classic_path = rc::stream_path('classic');
    my $resolved = _resolved($sid_dir, $classic_path);
    my $closed = _mod_closed();

    # A stale marker counts as no marker for the name, the dispatch and the proof (F2-2).
    my $stale = stale_marker(nonce => $mn, sha => $s->{sha256}, sid => $sid, sid_dir => $sid_dir, cwd => $cwd,
                             dispatch => $rec, resolved => $resolved);
    my $emn = $stale ? undef : $mn;
    my $erec = $stale ? undef : $rec;
    my $id6 = copies::id6($emn, $s->{sha256});

    # 1. stash (0600, unique name), so reconcile can save if we die or defer
    eval { util::write_excl("$sid_dir/pending/$id6.post.md", $text, 0600) };

    # 2. dispatch lookup; time join only for seat/channel/trigger, never as scope proof
    my ($tjoin) = grep { ($_->{trigger} // '') ne 'precompute' && !$resolved->{ $_->{nonce} } && !$closed->{ $_->{nonce} }
                         && $_->{_epoch} >= $now - 120 && $_->{_epoch} <= $now + 5 } reverse @all;
    my $drec = $erec // $tjoin;
    my $join = $erec ? 'nonce' : $tjoin ? 'time' : undef;

    # Scope from the proofs a hook can use: P1 (the dispatch record) and P2 (s=sub). P3
    # (boundary rows) waits for the next Stop: the row is not written yet (S-21, F2-1).
    my $sp = scope::prove(dispatch => $erec, marker_scope => ($stale ? undef : $s->{scope}));
    my $scope = $sp->{scope};
    my $agent = $sp->{agent_id};
    my $boundary = own_boundary(scope => $scope, agent => $agent, transcript => $tp, sid => $sid, dispatch => $drec);
    my $precomputed = ($boundary && $boundary->{precomputed}) || ($drec && ($drec->{trigger} // '') eq 'precompute') ? 1 : 0;
    my $tokens = $boundary ? [$boundary->{pre}, $boundary->{post}] : undef;

    # defer rule (MOD-SPEC §5.3 step 2): no usable marker, and an unresolved mod-hook/mod-self
    # dispatch <= 600 s old that can still get its after-step. The newest open dispatch
    # decides: a newer classic one (a PreCompact fallback) means this compaction is the
    # classic one; a dispatch the mod logged as rejected or skipped gets no after-step.
    my $deferred;
    if (!defined $emn) {
        my ($open) = grep { ($_->{trigger} // '') ne 'precompute' && !$resolved->{ $_->{nonce} } && !$closed->{ $_->{nonce} }
                            && $_->{_epoch} >= $now - 600 } reverse @all;
        $deferred = $open if $open && dispatch::is_mod($open);
    }
    # F2-1: nothing proves the scope here -> no save and no sweep now; reconcile proves it
    # with P3 at the next Stop and saves (main, sub, or unattributed when still unknown).
    my $scope_deferred = (!$deferred && $scope eq 'unknown') ? 1 : 0;
    eval {
        util::write_excl("$sid_dir/pending/$id6.post.json", jsonc::encode_bytes(jsonc::obj(
            id6 => $id6, nonce => $emn, scope => $scope, agent => $agent, trigger => $p->{trigger}, cwd => $cwd,
            transcript => $tp, tokens => $tokens, precomputed => jsonc::bool($precomputed),
            ts => util::iso_ms($now), dispatch => ($drec ? $drec->{nonce} : undef), deferred => ($deferred ? $deferred->{nonce} : undef),
            scope_deferred => jsonc::bool($scope_deferred), stale => jsonc::bool($stale), marker => $mn,
            join => $join)) . "\n", 0600);
    };
    my %vc = (precomputed => $precomputed, scope => $scope);
    if (defined $mn) {
        $vc{marker_has_record} = $rec ? 1 : 0;
        $vc{marker_earlier} = 1 if $stale;
    }
    my $verdict = detect::verdict($s, %vc);
    my ($seat, $esc) = seat_state($drec, $tp);
    my $channel = $drec ? $drec->{channel} : 'none';
    my $trigger = _trigger($drec, $p->{trigger});
    my $cp = $drec ? util::read_file("$sid_dir/checkpoint/$drec->{nonce}.json") : undef;
    my $cj = defined $cp ? eval { jsonc::decode($cp) } : undef;

    my ($save, $sweep);
    if ($deferred) {
        rc::emit('copy_deferred', [nonce => $deferred->{nonce}, id6 => $id6, why => 'mod']);
        rc::emit('verdict', [nonce => undef, verdict => $verdict, verdict_source => 'postcompact',
                             marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end}]);
    } elsif ($scope_deferred) {
        rc::emit('copy_deferred', [nonce => ($drec ? $drec->{nonce} : $emn), id6 => $id6, why => 'scope']);
    } else {
        my $lane = ref $cj eq 'HASH' ? $cj->{lane} : undef;
        if (!defined $lane && $scope eq 'main' && defined rc::val('queue_cmd') && rc::val('queue_cmd') ne '') {
            my $l = queue::lane($sid, rc::val('queue_cmd'), 3000);
            if ($l->{status} eq 'ok') { $lane = $l->{lane} } elsif (!$l->{silent}) { rc::emit('lane_unknown', [why => $l->{why} // $l->{status}]) }
        }
        my $evid = ref $cj eq 'HASH' && ref $cj->{evidence_map} eq 'ARRAY' ? { source => 'checkpoint', rows => scalar @{ $cj->{evidence_map} } } : undef;
        $save = copies::save(sid => $sid, text => $text, scan => $s, nonce => $emn, content_name => $stale,
                             writer => 'postcompact-fallback',
                             scope => $scope, agent => $agent, tokens => $tokens, cwd => $cwd, transcript => $tp,
                             trigger => $trigger, dispatch => $erec, seat_state => $seat, channel => $channel,
                             precomputed => $precomputed, verdict => $verdict, queue_lane => $lane, evidence => $evid);
        copies::drop_stash("$sid_dir/pending/$id6.post.md", $save->{result});
        # Main-proven: sweep whatever the save outcome (MOD-SPEC §5.3 step 5); a refused
        # copy under an unsafe handoff_root does not stop evidence going to the
        # disposable root, which sweep checks on its own.
        if ($scope eq 'main') {
            (my $stem = util::basename($save->{path} // '')) =~ s/\.md$//;
            $stem = util::stamp($now) . '_' . substr($sid, 0, 8) . "-$id6" if $stem eq '';
            $sweep = sweep::run(sid => $sid, id6 => $id6, stem => $stem, transcript => $tp, budget_ms => 8000,
                                bucket => ($save->{bucket} ? $save->{bucket}{path} : undef), nonce => $emn);
        }
    }
    # boundaries.count is reconcile's now: it matches boundary rows to PostCompacts (F2-1).

    my $actor = $scope eq 'main' ? 'main' : $scope eq 'sub' ? ($agent // 'sub-unknown') : 'unattributed';
    # Deferred to the mod's after-step: the defer rule takes the summary as that dispatch's,
    # whose after-step saves it with the scope the mod knows; the rollup row carries that
    # dispatch's actor and nonce (no save or sweep happens here on it).
    if ($deferred) { $actor = $deferred->{agent_id} // 'main'; $drec = $deferred }
    my $claim = $drec ? util::read_file("$sid_dir/resume-claimed/$drec->{nonce}") : undef;
    my $resume = $actor ne 'main' && $actor ne 'unattributed' ? 'none-subagent' : defined $claim ? 'delivered:' . ($claim =~ /^(\S+)/)[0] : undef;
    my $tot = $sweep ? $sweep->{totals} : undef;
    my $measured = $drec && grep { $_ eq 'measured' } @{ $drec->{tags} || [] };
    # A scope-deferred compaction gets its one rollup row from reconcile, with the proven actor.
    rollup::write(
        session_id => $sid, actor => $actor, compaction_seq => ($save ? $save->{seq} : undef),
        nonce => ($drec ? $drec->{nonce} : $emn), id6 => $id6, join => $join, trigger => $trigger,
        midturn => ($drec ? $drec->{midturn} : undef), idle => 'unknown', channel => $channel, seat_state => $seat,
        verdict => $verdict, verdict_source => 'postcompact', marker_line => $s->{marker_line},
        sentinel_from_end => $s->{sentinel_from_end},
        fabricated_check_tokens => ($measured ? 0 : detect::fabricated_check_tokens($s->{normalized})),
        instructions_bytes => ($drec ? $drec->{instructions_bytes} : undef), summary_chars => $s->{chars},
        shape_class => detect::shape_class($s), pre_tokens => ($boundary ? $boundary->{pre} : undef),
        post_tokens => ($boundary ? $boundary->{post} : undef), duration_ms => ($boundary ? $boundary->{duration_ms} : undef),
        precomputed => jsonc::bool($precomputed),
        copy => ($save ? $save->{result} : undef), copy_path => ($save ? $save->{rel} : undef), resume => $resume,
        checkpoint_ms => (ref $cj eq 'HASH' ? $cj->{checkpoint_ms} : undef),
        evidence => ($tot ? { copied => $tot->{copied}, dup => $tot->{dup}, ref_only => $tot->{'ref-only'},
                              redacted => $tot->{redacted}, withheld => $tot->{withheld} } : undef),
        nudged => undef, continued => undef, halt => undef,
    ) unless $scope_deferred;
    rc::emit('scope_leak', [nonce => $mn, scope => $scope, marker_scope => $s->{scope}]) if $verdict eq 'scope-leak';
    rc::emit('layers_missing', [id6 => $id6, trigger => $trigger]) if $seat eq 'none' && $scope ne 'sub';
    if (defined $esc) {
        if ($esc eq 'bypass_suspected') {
            rc::emit('bypass_suspected', [nonce => $drec->{nonce}, causes => ['seat', 'rollout-switch', 'unload']]) if rc::once('bypass_suspected');
        } else {
            rc::emit('mod_off', [nonce => $drec->{nonce}]) if rc::once('mod_off');
        }
    }
    return { scan => $s, verdict => $verdict, scope => $scope, seat_state => $seat, id6 => $id6, channel => $channel,
             scope_deferred => $scope_deferred };
}

1;

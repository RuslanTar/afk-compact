package postcompact;
# lib/postcompact.pm: classic PostCompact, the primary saver (MOD-SPEC §5.3 steps 1-6).
# Owner: WP-core. Steps: stash; nonce from the marker; dispatch lookup; scope proof
# (§2.4); defer rule (copy_deferred); save-copy --writer postcompact-fallback (secret
# scan inside); main-proven sweep (8 s budget); boundaries.count; rollup, verdict and
# escalation rows. Returns the detector run for watch.on_hook.
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
    my $id6 = copies::id6($mn, $s->{sha256});

    # 1. stash (0600, unique name) + its meta, so reconcile can save if we die
    eval { util::write_excl("$sid_dir/pending/$id6.post.md", $text, 0600) };

    # 2. dispatch lookup; time join only for seat/channel/trigger, never as scope proof
    my $rec = defined $mn ? dispatch::read($watch, $sid, $mn) : undef;
    my @all = dispatch::all($watch, $sid);
    my $classic_path = rc::stream_path('classic');
    my $resolved = _resolved($sid_dir, $classic_path);
    my $closed = _mod_closed();
    my ($tjoin) = grep { ($_->{trigger} // '') ne 'precompute' && !$resolved->{ $_->{nonce} } && !$closed->{ $_->{nonce} }
                         && $_->{_epoch} >= $now - 120 && $_->{_epoch} <= $now + 5 } reverse @all;
    my $drec = $rec // $tjoin;
    my $join = $rec ? 'nonce' : $tjoin ? 'time' : undef;

    my $sp = scope::prove(dispatch => $rec, marker_scope => $s->{scope}, transcript => $tp, sid => $sid,
                          sid_dir => $sid_dir, since => ($drec ? $drec->{_epoch} : $now - 120));
    my $scope = $sp->{scope};
    my $agent = $sp->{agent_id};
    my $boundary;
    if ($scope eq 'main' || $sp->{p3_main}) {
        my $b = transcript::boundaries($tp);
        $boundary = $b->[-1] if @$b;
    } elsif ($scope eq 'sub') {
        for my $f (@{ transcript::subagent_files($tp, $sid) }) {
            next if defined $agent && $f->{agent_id} ne $agent;
            my $b = transcript::boundaries($f->{path});
            $boundary = $b->[-1] if @$b;
            last if $boundary;
        }
    }
    my $precomputed = $boundary && $boundary->{precomputed} ? 1 : 0;
    my $tokens = $boundary ? [$boundary->{pre}, $boundary->{post}] : undef;

    # defer rule (MOD-SPEC §5.3 step 2): no marker, and an unresolved mod-hook/mod-self
    # dispatch <= 600 s old that can still get its after-step. The newest open dispatch
    # decides: a newer classic one (a PreCompact fallback) means this compaction is the
    # classic one; a dispatch the mod logged as rejected or skipped gets no after-step.
    my $deferred;
    if (!defined $mn) {
        my ($open) = grep { ($_->{trigger} // '') ne 'precompute' && !$resolved->{ $_->{nonce} } && !$closed->{ $_->{nonce} }
                            && $_->{_epoch} >= $now - 600 } reverse @all;
        $deferred = $open if $open && dispatch::is_mod($open);
    }
    eval {
        util::write_excl("$sid_dir/pending/$id6.post.json", jsonc::encode_bytes(jsonc::obj(
            id6 => $id6, nonce => $mn, scope => $scope, agent => $agent, trigger => $p->{trigger}, cwd => $cwd,
            transcript => $tp, tokens => $tokens, precomputed => jsonc::bool($precomputed),
            ts => util::iso($now), dispatch => ($drec ? $drec->{nonce} : undef), deferred => ($deferred ? $deferred->{nonce} : undef))) . "\n", 0600);
    };
    my %vc = (precomputed => $precomputed, scope => $scope);
    if (defined $mn) {
        $vc{marker_has_record} = $rec ? 1 : 0;
        if ($rec && $resolved->{$mn}) {
            my $bk = bucket::resolve($sid, $cwd);
            my $ex = copies::find($bk->{path}, $id6);
            if ($ex) { my ($esha) = copies::copy_sha($ex); $vc{marker_earlier} = 1 if defined $esha && $esha ne $s->{sha256} }
        }
    }
    my $verdict = detect::verdict($s, %vc);
    my ($seat, $esc) = seat_state($drec, $tp);
    my $channel = $drec ? $drec->{channel} : 'none';
    my $trigger = _trigger($drec, $p->{trigger});
    my $cp = $drec ? util::read_file("$sid_dir/checkpoint/$drec->{nonce}.json") : undef;
    my $cj = defined $cp ? eval { jsonc::decode($cp) } : undef;

    my ($save, $sweep);
    if ($deferred) {
        rc::emit('copy_deferred', [nonce => $deferred->{nonce}, id6 => $id6]);
        rc::emit('verdict', [nonce => undef, verdict => $verdict, verdict_source => 'postcompact',
                             marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end}]);
    } else {
        my $lane = ref $cj eq 'HASH' ? $cj->{lane} : undef;
        if (!defined $lane && $scope eq 'main' && defined rc::val('queue_cmd') && rc::val('queue_cmd') ne '') {
            my $l = queue::lane($sid, rc::val('queue_cmd'), 3000);
            if ($l->{status} eq 'ok') { $lane = $l->{lane} } elsif (!$l->{silent}) { rc::emit('lane_unknown', [why => $l->{why} // $l->{status}]) }
        }
        my $evid = ref $cj eq 'HASH' && ref $cj->{evidence_map} eq 'ARRAY' ? { source => 'checkpoint', rows => scalar @{ $cj->{evidence_map} } } : undef;
        $save = copies::save(sid => $sid, text => $text, scan => $s, nonce => $mn, writer => 'postcompact-fallback',
                             scope => $scope, agent => $agent, tokens => $tokens, cwd => $cwd, transcript => $tp,
                             trigger => $trigger, dispatch => $rec, seat_state => $seat, channel => $channel,
                             precomputed => $precomputed, verdict => $verdict, queue_lane => $lane, evidence => $evid);
        copies::drop_stash("$sid_dir/pending/$id6.post.md", $save->{result});
        # Main-proven: sweep whatever the save outcome (MOD-SPEC §5.3 step 5); a refused
        # copy under an unsafe handoff_root does not stop evidence going to the
        # disposable root, which sweep checks on its own.
        if ($scope eq 'main') {
            (my $stem = util::basename($save->{path} // '')) =~ s/\.md$//;
            $stem = util::stamp($now) . '_' . substr($sid, 0, 8) . "-$id6" if $stem eq '';
            $sweep = sweep::run(sid => $sid, id6 => $id6, stem => $stem, transcript => $tp, budget_ms => 8000,
                                bucket => ($save->{bucket} ? $save->{bucket}{path} : undef), nonce => $mn);
        }
    }
    # boundaries.count after every main-proven PostCompact, whatever the save outcome
    if ($scope eq 'main' && defined $sp->{main_count}) {
        eval { scope::set_count($sid_dir, $sp->{main_count}, { sid => $sid, actor => 'main' }) };
    }

    my $actor = $scope eq 'main' ? 'main' : $scope eq 'sub' ? ($agent // 'sub-unknown') : 'unattributed';
    my $claim = $drec ? util::read_file("$sid_dir/resume-claimed/$drec->{nonce}") : undef;
    my $resume = $scope eq 'sub' ? 'none-subagent' : defined $claim ? 'delivered:' . ($claim =~ /^(\S+)/)[0] : undef;
    my $tot = $sweep ? $sweep->{totals} : undef;
    my $measured = $drec && grep { $_ eq 'measured' } @{ $drec->{tags} || [] };
    rollup::write(
        session_id => $sid, actor => $actor, compaction_seq => ($save ? $save->{seq} : undef),
        nonce => ($drec ? $drec->{nonce} : $mn), id6 => $id6, join => $join, trigger => $trigger,
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
    );
    rc::emit('scope_leak', [nonce => $mn, scope => $scope, marker_scope => $s->{scope}]) if $verdict eq 'scope-leak';
    rc::emit('layers_missing', [id6 => $id6, trigger => $trigger]) if $seat eq 'none' && $scope ne 'sub';
    if (defined $esc) {
        if ($esc eq 'bypass_suspected') {
            rc::emit('bypass_suspected', [nonce => $drec->{nonce}, causes => ['seat', 'rollout-switch', 'unload']]) if rc::once('bypass_suspected');
        } else {
            rc::emit('mod_off', [nonce => $drec->{nonce}]) if rc::once('mod_off');
        }
    }
    return { scan => $s, verdict => $verdict, scope => $scope, seat_state => $seat, id6 => $id6, channel => $channel };
}

1;

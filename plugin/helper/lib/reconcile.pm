package reconcile;
# lib/reconcile.pm: the reconciler at a main turn end (MOD-SPEC §5.4; classic Stop, <= 2 s).
# Owner: WP-core.
#   - a stashed PostCompact or mod summary with no copy -> save it now, `copy_late`
#   - a non-precompute dispatch older than 10 min with no PostCompact and no
#     after-step -> `compaction_unresolved`; a precompute dispatch never followed
#     by an install -> `precompute_not_reused` (counted, never a failure)
#   - order canary C6: a boundary row with no PostCompact, or a PostCompact with no
#     PreCompact and no `precomputed` -> `order_anomaly`
#   - an undelivered main resume block -> `resume_undelivered`
# Every row is written once (reconcile reads the rows it wrote before).
use strict;
use warnings;

our @OWN_ROWS = qw(copy_late compaction_unresolved precompute_not_reused order_anomaly resume_undelivered);

sub _before_epoch {
    my ($rows) = @_;
    my $min;
    for my $r (@$rows) { my $e = util::parse_iso($r->{ts} // '') // next; $min = $e if !defined $min || $e < $min }
    return $min;
}

# run(transcript => P, cwd => C, budget_ms => 2000, cutoff => epoch) -> {late, unresolved, precompute_not_reused, order_anomaly, undelivered}
sub run {
    my (%a) = @_;
    my $sid = rc::sid();
    my $sid_dir = rc::sid_dir() // return {};
    my $watch = rc::watch();
    my $t0 = util::clock_ms();
    my $deadline = $t0 + ($a{budget_ms} // 2000);
    my $now = util::now();
    my %n = (late => 0, unresolved => 0, precompute_not_reused => 0, order_anomaly => 0, undelivered => 0);
    # only the rows reconcile reads (its own rows, copies, PreCompact rows): a long
    # session's other rows are skipped before the decode (the Stop budget)
    my $classic = rollup::stream_rows(rc::stream_path('classic'), evs => [@OWN_ROWS, qw(copy precompact precompact_shaped
                                                                                            precompact_marker_orphan precompact_fallback)]);
    my $rolls = rollup::rows($sid_dir);
    my (%copied, %logged, %rolled_id6, %rolled_nonce);
    for my $r (@$classic) {
        my $ev = $r->{ev} // '';
        if ($ev eq 'copy' && ($r->{result} // '') !~ /^failed/) {
            # the value: the copy's path under <root> (a stash with the same body can go, F2-7)
            my $rel = ($r->{result} // '') eq 'mismatch' ? '' : ($r->{rel_path} // '');
            $copied{ $r->{id6} } = $rel if defined $r->{id6};
            $copied{ 'n:' . $r->{nonce} } = $rel if defined $r->{nonce};
        }
        $logged{"$ev:" . ($r->{nonce} // $r->{uuid} // $r->{id6} // '')} = 1;
    }
    for my $r (@$rolls) {
        $rolled_id6{ $r->{id6} } = $r if defined $r->{id6};
        $rolled_nonce{ $r->{nonce} } = $r if defined $r->{nonce};
    }
    my @disp = dispatch::all($watch, $sid);
    my %disp = map { $_->{nonce} => $_ } @disp;

    # 1. stashes without a copy. Not while handoff_root is refused (MOD-SPEC §1.2): every
    # save would be refused again and log another failed copy row at each Stop; the
    # stashes wait for a later Stop with a safe root (the refusal row is once per session).
    my @pending = rc::root_ok('handoff_root') ? util::list_dir("$sid_dir/pending") : ();
    # A stash whose summary a copy already holds (same normalized body) is dropped (F2-7).
    my $drop_if_held = sub {
        my ($f, $rel, $text) = @_;
        return unless defined $rel && $rel ne '';
        my ($csha) = copies::copy_sha(rc::root() . "/$rel");
        copies::drop_stash("$sid_dir/pending/$f", 'exists')
            if defined $csha && $csha eq sha::hex256(detect::scan($text)->{normalized});
    };
    for my $f (@pending) {
        last if util::clock_ms() > $deadline;
        my ($id6, $kind, $nonce);
        if ($f =~ /^([0-9a-f]{6}|h[0-9a-f]{5}(?:-\d+)?)\.post\.md$/) { ($id6, $kind) = ($1, 'post') }
        elsif ($f =~ /^([0-9a-f]{8})\.mod\.md$/) { ($nonce, $kind) = ($1, 'mod'); $id6 = substr($1, 0, 6) }
        else { next }
        if (exists $copied{$id6} || (defined $nonce && exists $copied{"n:$nonce"})) {
            my $text = util::read_file("$sid_dir/pending/$f");
            $drop_if_held->($f, (exists $copied{$id6} ? $copied{$id6} : $copied{"n:$nonce"}), $text) if defined $text;
            next;
        }
        my $text = util::read_file("$sid_dir/pending/$f") // next;
        my %m;
        if ($kind eq 'post') {
            my $raw = util::read_file("$sid_dir/pending/$id6.post.json");
            my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
            %m = %$j if ref $j eq 'HASH';
            # a deferred unmarked summary: the after-step's nonce, if it ever saved, is copied under it
            if (!defined $m{nonce} && defined $m{deferred} && exists $copied{"n:$m{deferred}"}) {
                $drop_if_held->($f, $copied{"n:$m{deferred}"}, $text);
                next;
            }
        }
        my $s = detect::scan($text);
        my $mn = $nonce // $m{nonce} // $s->{nonce};
        # P1 (MOD-SPEC §2.4): the record of the nonce in the mod stash name or the summary marker
        my $p1 = defined $mn ? $disp{$mn} : undef;
        my $drec = $p1 // (defined $m{deferred} ? $disp{ $m{deferred} } : undef);
        # a deferred stash is named under its pending mod dispatch (as the after-step would
        # save it), but that dispatch is no scope proof: the scope stays the stash's own
        if (!defined $mn && $drec && dispatch::is_mod($drec)) { $mn = $drec->{nonce} }
        my $scope = $m{scope} // 'unknown';
        if ($p1 && dispatch::is_mod($p1)) { $scope = defined $p1->{agent_id} ? 'sub' : 'main' }
        my $agent = $m{agent} // ($p1 ? $p1->{agent_id} : undef);
        if (defined $mn && exists $copied{"n:$mn"}) { $drop_if_held->($f, $copied{"n:$mn"}, $text); next }
        my $save = copies::save(sid => $sid, text => $text, scan => $s, nonce => $mn,
                                writer => ($kind eq 'mod' ? 'mod' : 'postcompact-fallback'),
                                scope => $scope, agent => $agent, tokens => $m{tokens}, cwd => $m{cwd} // $a{cwd},
                                transcript => $m{transcript} // $a{transcript}, trigger => ($drec ? $drec->{trigger} : $m{trigger}),
                                dispatch => $drec, channel => ($drec ? $drec->{channel} : 'none'),
                                precomputed => $m{precomputed}, late => 1,
                                verdict_ctx => { dispatch_nonce => ($drec ? $drec->{nonce} : undef) });
        copies::drop_stash("$sid_dir/pending/$f", $save->{result}) if $save->{exit} == 0;
        next unless $save->{exit} == 0 && $save->{result} eq 'late';
        $n{late}++;
        $copied{ $save->{id6} } = $save->{rel};
        $copied{"n:$mn"} = $save->{rel} if defined $mn;
        rc::emit('copy_late', [nonce => $mn, id6 => $save->{id6}, rel_path => $save->{rel}]);
        if (!$rolled_id6{$id6} && !(defined $mn && $rolled_nonce{$mn})) {
            rollup::write(session_id => $sid, actor => ($scope eq 'main' ? 'main' : $scope eq 'sub' ? ($agent // 'sub-unknown') : 'unattributed'),
                          compaction_seq => $save->{seq}, nonce => $mn, id6 => $save->{id6}, join => 'reconcile',
                          trigger => ($drec ? $drec->{trigger} : $m{trigger}), idle => 'unknown',
                          channel => ($drec ? $drec->{channel} : 'none'), seat_state => ($drec ? (postcompact::seat_state($drec, $a{transcript}))[0] : 'none'),
                          verdict => $save->{verdict}, verdict_source => ($kind eq 'mod' ? 'after-step' : 'postcompact'),
                          marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end},
                          summary_chars => $s->{chars}, shape_class => detect::shape_class($s),
                          copy => 'late', copy_path => $save->{rel});
        }
    }

    # The transcript scan reads the whole file: not started once the budget is spent
    # (steps 2 and 3 need its boundaries, so both wait for the next Stop).
    my $in_time = util::clock_ms() <= $deadline;

    # 2. unresolved and precompute dispatches (> 10 min old)
    my $bounds = $in_time && defined $a{transcript} ? transcript::boundaries($a{transcript}) : [];
    for my $d ($in_time ? @disp : ()) {
        last if util::clock_ms() > $deadline;
        next unless $d->{_epoch} && $now - $d->{_epoch} > 600 && $now - $d->{_epoch} < 7 * 86400;
        my $nn = $d->{nonce};
        if (($d->{trigger} // '') eq 'precompute') {
            next if $logged{"precompute_not_reused:$nn"};
            next if grep { $_->{precomputed} && $_->{epoch} >= $d->{_epoch} } @$bounds;
            rc::emit('precompute_not_reused', [nonce => $nn]);
            $n{precompute_not_reused}++;
            next;
        }
        next if $rolled_nonce{$nn} || exists $copied{"n:$nn"} || $logged{"compaction_unresolved:$nn"};
        next if -e "$sid_dir/pending/$nn.mod.md";
        rc::emit('compaction_unresolved', [nonce => $nn, trigger => $d->{trigger}, channel => $d->{channel}]);
        $n{unresolved}++;
    }

    # 3. order canary C6 (only for boundaries after this session's first record)
    my $cutoff = $a{cutoff};
    if (defined $cutoff && $in_time) {
        for my $b (@$bounds) {
            last if util::clock_ms() > $deadline;
            next unless $b->{epoch} >= $cutoff && $now - $b->{epoch} > 15;
            next if $logged{"order_anomaly:" . ($b->{uuid} // '')};
            my $has = grep { my $e = util::parse_iso($_->{ts} // '') // 0; abs($e - $b->{epoch}) <= 120 } @$rolls;
            next if $has;
            rc::emit('order_anomaly', [uuid => $b->{uuid}, kind => 'boundary-without-postcompact']);
            $n{order_anomaly}++;
        }
        my @pre = grep { ($_->{ev} // '') =~ /^precompact/ } @$classic;
        for my $r (@$rolls) {
            next if $r->{precomputed} || ($r->{join} // '') eq 'reconcile';
            my $e = util::parse_iso($r->{ts} // '') // next;
            next unless $e >= $cutoff;
            my $key = "order_anomaly:" . ($r->{id6} // '');
            next if $logged{$key};
            next if grep { my $pe = util::parse_iso($_->{ts} // '') // 0; $pe <= $e + 1 && $pe >= $e - 900 } @pre;
            rc::emit('order_anomaly', [id6 => $r->{id6}, nonce => $r->{nonce}, kind => 'postcompact-without-precompact']);
            $logged{$key} = 1;
            $n{order_anomaly}++;
        }
    }

    # 4. undelivered main resume blocks
    for my $r (@$rolls) {
        next unless ($r->{actor} // '') eq 'main' && defined $r->{nonce};
        my $e = util::parse_iso($r->{ts} // '') // next;
        next unless $now - $e > 30;
        next if -e "$sid_dir/resume-claimed/$r->{nonce}" || $logged{"resume_undelivered:$r->{nonce}"};
        rc::emit('resume_undelivered', [nonce => $r->{nonce}]);
        $logged{"resume_undelivered:$r->{nonce}"} = 1;
        $n{undelivered}++;
    }
    return \%n;
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

package watch::rules;
# lib/watch/rules.pm: the Stop-time rule engine (joins, realtime fields, rules A-01..A-29).
# Inputs: this
# session's rows (classic, mod, mod fallback events, dispatch records, rollup,
# sidecar slots) and the sweeper's new boundaries and events. Output: alert
# rows and `precompute_or_failed` info rows. Never acts.
#
# Time (F2-4): with `$ctx->{_deadline}` set (the Stop's
# hard stop, on the watch::io::mono clock) the engine checks the clock between
# compactions, events and rule blocks and dies "hard-stop\n" once it has
# passed. Everything the rules write is idempotent (alert ids; one
# `precompute_or_failed` row per PreCompact, deduped against the stream), so
# the caller drops the run and the next Stop evaluates the same input again.
use strict;
use warnings;
use utf8;
use watch::alerts;
use watch::cache;
use watch::ctx;
use watch::io;
use watch::json;
use watch::spec;
use watch::hturn;

my %BADV = map { $_ => 1 } qw(unshaped truncated stale);
my $JOIN_S = 120;
# A-28: a handoff turn's first request that read under this share of its input from the
# cache, at this many context tokens or more, is cold (the mod applies the same share to a
# compaction's prefix read and writes compaction_cold).
our $COLD_SHARE = 0.5;
our $COLD_MIN_TOKENS = 100_000;
# A-23: the idle compactions held for a later Stop at most (see _a23_held).
our $A23_HELD_MAX = 50;
# A-27: the main boundaries whose history and idle facts the session state keeps (bmeta).
our $BMETA_MAX = 50;
# The context window of the standard models (thresholds: a larger autoCompactWindow needs a
# context seen above it)
our $STD_WINDOW = 200_000;
# A-24 (set below with the walk)
our ($WATCH_MB_CAP, $BELOW_QUOTA, $TASK_OUT_MAX);

# The row kinds the rules read from the classic and mod streams and from the
# mod's events/ files. Only these are decoded and kept (lib/watch/cache.pm);
# rows_of() of any other kind is empty, and test mode records the miss.
our @KINDS = qw(compact_command compact_rejected compacted config_effective continue copy copy_exists copy_failed
                copy_mismatch dispatch handoff_publish heal keyset_change order_anomaly postcompact
                precompact precompute_or_failed resume_inject resume_receipt stop_failure sweep_partial
                thrash trigger_disabled_small_window trigger_unknown triggers_off version_change
                warn_quota watch_error
                handoff_export handoff_mode handoff_race handoff_skipped handoff_turn_open
                handoff_user_interjected jobs_caller_refused queue_add relaunch_unmatched
                permission_denied
                stash_dropped stash_kept copy_attributed copy_attribution_ambiguous copy_attribution_failed
                orphan_finished
                handoff_turn_start handoff_turn_end idle_mismatch resume_remeasured resume_remeasure_failed
                submit_dropped queue_contract approvals_carry compaction_cold idle_unshaped);
my %KIND = map { $_ => 1 } @KINDS;
our %MISSED;

sub _t { my $r = shift; $r->{_t} //= watch::io::parse_iso($r->{ts}); return $r->{_t} }

# Die "hard-stop\n" once the run's deadline has passed.
sub tick {
    my ($ctx) = @_;
    die "hard-stop\n" if defined $ctx->{_deadline} && watch::io::mono() >= $ctx->{_deadline};
    return 1;
}

# --- session model ----------------------------------------------------------

# The session model from a cache load (lib/watch/cache.pm). Without one, the
# rows are read here in full and nothing is persisted.
sub load_session {
    my ($ctx, $C) = @_;
    $C ||= watch::cache::load($ctx, kinds => \@KINDS);
    my %S = (by => {}, disp => {}, disp_list => []);
    for my $r (@{ $C->{rows}{classic} }, @{ $C->{rows}{mod} }, @{ $C->{rows}{events} }) {
        next unless defined $r->{ev} && $KIND{ $r->{ev} };
        _t($r);
        push @{ $S{by}{ $r->{ev} } }, $r;
    }
    for my $ev (keys %{ $S{by} }) {
        $S{by}{$ev} = [ sort { (_t($a) // 0) <=> (_t($b) // 0) } @{ $S{by}{$ev} } ];
    }
    for my $d (@{ $C->{rows}{dispatch} }) {
        next unless defined $d->{nonce} && !ref $d->{nonce};
        _t($d);
        $S{disp}{ $d->{nonce} } = $d;
    }
    $S{disp_list} = [ sort { (_t($a) // 0) <=> (_t($b) // 0) } values %{ $S{disp} } ];
    ($S{rollup}, $S{boundary}, $S{join_conflict}) = join_rollup($C->{rows}{rollup});
    $S{attributed} = attributed_by_id6(rows_of(\%S, 'copy_attributed'));
    $S{bg} = _bg_slots($ctx);
    return \%S;
}

# The rollup stream (<watch>/<sid>/compactions.jsonl) holds the rollup rows (`ev:
# compaction`, written before the store had an `ev` for them: no `ev`) and core's
# `compaction_boundary` rows (one per nonce, append-only). Join by nonce:
# a null rollup field takes the boundary value, a non-null rollup value is never replaced,
# and a disagreement is a `join_conflict` (named on the row as `_join_conflict`, counted).
# A repeated boundary row for a nonce is ignored (the first one counts).
our %JOIN_FIELDS = (pre_tokens => 'pre_tokens', post_tokens => 'post_tokens', duration_ms => 'duration_ms',
                    precomputed => 'precomputed');
our @JOIN_IDLE = qw(idle idle_source idle_gap_s);

sub join_rollup {
    my ($rows) = @_;
    my (%roll, %bound);
    for my $r (@{ $rows || [] }) {
        next unless ref $r eq 'HASH' && defined $r->{nonce} && !ref $r->{nonce};
        my $ev = $r->{ev} // 'compaction';
        if ($ev eq 'compaction_boundary') { $bound{ $r->{nonce} } //= $r }
        elsif ($ev eq 'compaction') { $roll{ $r->{nonce} } = $r }
    }
    my $conflicts = 0;
    for my $n (sort keys %roll) {
        my $b = $bound{$n} or next;
        $roll{$n} = join_row($roll{$n}, $b);
        $conflicts++ if $roll{$n}{_join_conflict};
    }
    return (\%roll, \%bound, $conflicts);
}

# join_row(rollup row, boundary row) -> a joined copy (neither row is changed): a null rollup
# field takes the boundary value, a non-null one is kept, and a disagreement is named in
# `_join_conflict`. `watch report` (lib/watch/report.pm) joins its rollup rows with it too.
sub join_row {
    my ($roll, $b) = @_;
    my $r = { %$roll };
    my @c;
    for my $k (sort keys %JOIN_FIELDS) {
        my $bv = $b->{ $JOIN_FIELDS{$k} };
        next unless defined $bv;
        if (!defined $r->{$k}) { $r->{$k} = $bv; next }
        my ($x, $y) = map { ref $_ eq 'SCALAR' ? ($$_ ? 1 : 0) : $_ } ($r->{$k}, $bv);
        push @c, $k if "$x" ne "$y";
    }
    # As core's rollup::rows: reconcile decides the idle
    # facts once the boundary row exists and writes them on the compaction_boundary row; the
    # PostCompact rollup row says `unknown` (or null) until then. Such a rollup value takes the
    # boundary's; a settled one is kept. No join_conflict: the rollup never settles idle itself.
    for my $k (@JOIN_IDLE) {
        next unless exists $b->{$k};
        $r->{$k} = $b->{$k} if !defined $r->{$k} || (!ref $r->{$k} && $r->{$k} eq 'unknown');
    }
    $r->{boundary_uuid} //= $b->{boundary_uuid};
    $r->{_join_conflict} = \@c if @c;
    return $r;
}

# The newest `copy_attributed` row per id6. The
# copy-path and actor joins take it over the `copy` row and the rollup row (read-only).
sub attributed_by_id6 {
    my (@rows) = @_;
    my %a;
    for my $r (sort { (_t($a) // 0) <=> (_t($b) // 0) } @rows) {
        next unless defined $r->{id6} && !ref $r->{id6};
        $a{ $r->{id6} } = $r;
    }
    return \%a;
}

# `permission_denied` rows (core's hook; the deny rate): counts by
# `turn_kind` (`post-compaction` includes the pending-record case),
# `caused_by` and `guard_class`. `reason_class` `classifier-unavailable` is kept apart as
# the control: such a row counts in `control`, not in `guard_class`. Content-free:
# classes and counts only. `watch report` (lib/watch/report.pm) counts with deny_counts.
sub deny_summary {
    my ($S) = @_;
    return deny_counts([ rows_of($S, 'permission_denied') ]);
}

sub deny_counts {
    my ($rows) = @_;
    my %o = (total => 0, control => 0, turn_kind => {}, caused_by => {}, guard_class => {}, post_compaction_plugin => 0);
    for my $r (@{ $rows || [] }) {
        next unless ref $r eq 'HASH';
        $o{total}++;
        my %v = map { my $x = $r->{$_}; ($_ => (defined $x && !ref $x && length $x) ? $x : 'unknown') }
                qw(turn_kind caused_by guard_class);
        $o{$_}{ $v{$_} }++ for qw(turn_kind caused_by);
        if (($r->{reason_class} // '') eq 'classifier-unavailable') { $o{control}++ }
        else { $o{guard_class}{ $v{guard_class} }++ }
        $o{post_compaction_plugin}++ if $v{turn_kind} eq 'post-compaction' && $v{caused_by} eq 'plugin';
    }
    return \%o;
}

sub rows_of {
    my ($S, $ev) = @_;
    $MISSED{$ev}++ if !$KIND{$ev} && ($ENV{STORE_TEST_MODE} || '') eq '1';
    return @{ $S->{by}{$ev} || [] };
}

sub _bg_slots {
    my ($ctx) = @_;
    my $dir = watch::ctx::sid_dir($ctx) . '/bg';
    my @slots;
    for my $f (watch::io::list_dir($dir)) {
        next unless $f =~ /\Aslot-[0-9]+\.json\z/;
        my $d = watch::io::read_json_file("$dir/$f") or next;
        my @st = stat "$dir/$f";
        my $tasks = $d->{tasks} // $d->{background_tasks} // [];
        next unless ref $tasks eq 'ARRAY';
        push @slots, { mtime => $st[9], ts => watch::io::parse_iso($d->{ts}),
                       tasks => [ grep { ref $_ eq 'HASH' } @$tasks ] };
    }
    return [ sort { ($a->{ts} // $a->{mtime}) <=> ($b->{ts} // $b->{mtime}) } @slots ];
}

# Effective thresholds: the mod's latest config_effective row, else the
# threshold clamp over the settings when the window is configured.
sub thresholds {
    my ($ctx, $S, $seen) = @_;
    return { off => 1 } if rows_of($S, 'triggers_off') || rows_of($S, 'trigger_disabled_small_window');
    my ($cfg) = reverse rows_of($S, 'config_effective');
    # A disabled row has null thresholds and the computed values in
    # soft_max_raw / target_raw, which are never thresholds (they can be negative): off.
    return { off => 1, why => $cfg->{disabled} }
        if $cfg && defined $cfg->{disabled} && !ref $cfg->{disabled} && length $cfg->{disabled};
    if ($cfg) {
        my $g = sub { for (@_) { return $cfg->{$_} if defined $cfg->{$_} && !ref $cfg->{$_} } return undef };
        my %t = (target => $g->(qw(target target_tokens compact_target_tokens)),
                 soft_max => $g->(qw(soft_max soft_max_tokens compact_soft_max_tokens)),
                 window => $g->(qw(window native_window_tokens context_window)),
                 native => $g->(qw(native_trigger native_trigger_tokens)));
        $t{native} //= $t{window} - clamp_constants($ctx->{spec})->{native_offset} if defined $t{window};
        return \%t if defined $t{target} && defined $t{soft_max} && defined $t{native};
    }
    # 0.1.4: Claude Code never compacts past the model's own window (the mod caps the setting at
    # it). The watcher does not know that window: a setting above the standard $STD_WINDOW counts
    # only once the session's context has been above $STD_WINDOW (`seen`, the largest main
    # boundary's tokens before), so the model's window is a larger one; else no thresholds.
    my $ccw = cc_compact_window($ctx);
    $ccw = undef if defined $ccw && $ccw > $STD_WINDOW && !(($seen // 0) > $STD_WINDOW);
    return fallback_thresholds($ctx->{settings}, $ctx->{spec}, $ccw);
}

# cc_compact_window(ctx) -> the window Claude Code's `autoCompactWindow` setting names (0.1.4, the
# watcher's copy of the mod's compactWindowSetting/settingWindow, plugin/hooks/lib/deps.ts and
# config.ts): the merged settings, read from the files Claude Code merges them from, the later one
# winning: <config dir>/settings.json (CLAUDE_CONFIG_DIR, else ~/.claude), the project's
# .claude/settings.json and .claude/settings.local.json (the project root Claude Code reads them
# from, CLAUDE_PROJECT_DIR, else the payload's cwd), then the managed settings file. A JSON number
# above 0 counts, floored at the clamp's window_floor (100,000). The mod also caps it at the model's
# own window, which the watcher does not know: thresholds() uses it only where that cap cannot
# change it. undef when unset or unreadable.
sub cc_compact_window {
    my ($ctx) = @_;
    return $ctx->{_cc_window} if exists $ctx->{_cc_window};
    my $cd = (defined $ENV{CLAUDE_CONFIG_DIR} && length $ENV{CLAUDE_CONFIG_DIR}) ? $ENV{CLAUDE_CONFIG_DIR}
           : (defined $ENV{HOME} && length $ENV{HOME}) ? "$ENV{HOME}/.claude" : undef;
    my $proj = (defined $ENV{CLAUDE_PROJECT_DIR} && length $ENV{CLAUDE_PROJECT_DIR}) ? $ENV{CLAUDE_PROJECT_DIR}
             : ref $ctx->{payload} eq 'HASH' && defined $ctx->{payload}{cwd} && !ref $ctx->{payload}{cwd} ? $ctx->{payload}{cwd} : undef;
    my $managed = $^O eq 'darwin' ? '/Library/Application Support/ClaudeCode/managed-settings.json'
                : $^O =~ /\A(?:MSWin32|msys|cygwin)\z/ ? (($ENV{ProgramFiles} // $ENV{PROGRAMFILES} // 'C:/Program Files') . '/ClaudeCode/managed-settings.json')
                : '/etc/claude-code/managed-settings.json';
    my @files = ((defined $cd ? "$cd/settings.json" : ()),
                 (defined $proj && length $proj ? ("$proj/.claude/settings.json", "$proj/.claude/settings.local.json") : ()), $managed);
    my $v;
    for my $p (@files) {
        my $raw = watch::io::slurp($p, 1 << 20);
        next unless defined $raw && index($raw, 'autoCompactWindow') >= 0;
        my $j = eval { watch::json::decode($raw) };
        next unless ref $j eq 'HASH' && exists $j->{autoCompactWindow};
        my $x = $j->{autoCompactWindow};
        # a JSON number (a quoted "800000" is not one, as for the mod), above 0
        my $num = defined $x && !ref $x && $raw =~ /"autoCompactWindow"\s*:\s*-?[0-9]/ && $x =~ /\A[0-9]+(?:\.[0-9]+)?(?:[eE][+]?[0-9]+)?\z/ && $x > 0;
        $v = $num ? $x : undef;
    }
    my $floor = clamp_constants($ctx->{spec})->{window_floor};
    return $ctx->{_cc_window} = defined $v ? ($v < $floor ? $floor : int $v) : undef;
}

# The clamp constants: one shared source, the spec's `clamp` object
# (assets/handoff-spec.json, rendered for the mod too). A missing or non-numeric key takes
# the built-in value, which equals the mod's config.ts constant.
our %CLAMP = (native_offset => 33000, min_target => 120000, reserve_base => 52000,
              reserve_no_handoff => 100000, window_floor => 100000, soft_ratio => 0.8,
              target_num => 2, target_den => 3, handoff_tokens_min => 20000, handoff_tokens_max => 150000);

sub clamp_constants {
    my ($spec) = @_;
    my $c = ref $spec eq 'HASH' && ref $spec->{clamp} eq 'HASH' ? $spec->{clamp} : {};
    my %k;
    for my $n (keys %CLAMP) {
        my $v = $c->{$n};
        $k{$n} = (defined $v && !ref $v && $v =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $v > 0) ? 0 + $v : $CLAMP{$n};
    }
    return \%k;
}

# Fallback: with no mod row (classic-only), the threshold clamp over
# the settings, the same formula as the mod's clamp(): the window below the floor counts
# as the floor; `reserve` from `handoff_turn`/`handoff_turn_max_tokens`; disabled below
# `min_target`. `min_window` is the smallest window that stays enabled ('never' when the
# configured pair alone is below the minimum). Unknown window (0): undef.
# 0.1.4: with native_window_tokens unset, `cc_window` (Claude Code's autoCompactWindow,
# cc_compact_window) is the window, as the mod takes it.
sub fallback_thresholds {
    my ($s, $spec, $cc_window) = @_;
    return { off => 1, why => 'triggers-off' } if lc($s->{triggers} // 'true') eq 'false';
    my $w = $s->{native_window_tokens};
    $w = $cc_window unless $w && $w > 0;
    return undef unless $w && $w > 0;
    my $K = clamp_constants($spec);
    $w = $K->{window_floor} if $w < $K->{window_floor};
    my $ht = int($s->{handoff_turn_max_tokens} // 64000);
    $ht = $K->{handoff_tokens_min} if $ht < $K->{handoff_tokens_min};
    $ht = $K->{handoff_tokens_max} if $ht > $K->{handoff_tokens_max};
    my $reserve = ($s->{handoff_turn} // 'halt') eq 'off' ? $K->{reserve_no_handoff} : $K->{reserve_base} + $ht;
    my $native = $w - $K->{native_offset};
    my $soft = _min($s->{compact_soft_max_tokens}, $native - $reserve, _floor($K->{soft_ratio} * $w));
    my $tq = sub { _floor(($_[0] * $K->{target_num}) / $K->{target_den}) };
    my $target = _min($s->{compact_target_tokens}, $tq->($soft));
    # The smallest soft_max whose target reaches min_target, then the smallest window giving it.
    # Integer steps from a close start, with the same float expressions as the clamp.
    my $s0 = _ceil(($K->{min_target} * $K->{target_den}) / $K->{target_num});
    $s0-- while $s0 > 0 && $tq->($s0 - 1) >= $K->{min_target};
    $s0++ while $tq->($s0) < $K->{min_target};
    my $w0 = _ceil($s0 / $K->{soft_ratio});
    $w0-- while $w0 > 0 && _floor($K->{soft_ratio} * ($w0 - 1)) >= $s0;
    $w0++ while _floor($K->{soft_ratio} * $w0) < $s0;
    my $min_window = ($s->{compact_soft_max_tokens} >= $s0 && $s->{compact_target_tokens} >= $K->{min_target})
        ? _max($s0 + $K->{native_offset} + $reserve, $w0, $K->{window_floor}) : 'never';
    return { off => 1, why => 'trigger-disabled-small-window', window => $w, min_window => $min_window,
             soft_max_raw => $soft, target_raw => $target } if $target < $K->{min_target};
    return { target => $target, soft_max => $soft, window => $w, native => $native, min_window => $min_window };
}

sub _floor { my $x = shift; my $i = int $x; return $i > $x ? $i - 1 : $i }
sub _ceil { my $x = shift; my $i = int $x; return $i < $x ? $i + 1 : $i }
sub _max { my $m = shift; for (@_) { $m = $_ if $_ > $m } return $m }

sub _min { my $m = shift; for (@_) { $m = $_ if $_ < $m } return $m }

sub band {
    my ($th, $pre) = @_;
    return undef unless $th && defined $pre;
    return 'triggers-off' if $th->{off};
    return 'at-native' if $pre >= $th->{native} * 0.98;
    return 'above-softmax' if $pre >= $th->{soft_max};
    return 'in-band' if $pre >= $th->{target};
    return 'below-target';
}

# --- joins ------------------------------------------------------------------

sub _pkey { my $p = shift; return join '|', ($p->{ts} // ''), ($p->{nonce_found} // '') }

sub build_compactions {
    my ($ctx, $S, $sess, $boundaries) = @_;
    my %jp = map { $_ => 1 } @{ $sess->{jp} || [] };
    my %jd = map { $_ => 1 } @{ $sess->{jd} || [] };
    my @post = rows_of($S, 'postcompact');
    my @pre = rows_of($S, 'precompact');
    my @out;
    my $find_disp = sub {
        my ($P, $ref_t, $want_pre) = @_;
        if ($P && defined $P->{nonce_found} && $S->{disp}{ $P->{nonce_found} }) {
            return ($S->{disp}{ $P->{nonce_found} }, 'nonce');
        }
        if ($P && defined _t($P)) {
            for my $Q (reverse @pre) {
                my $qt = _t($Q) // next;
                next if $qt > _t($P) + 1 || _t($P) - $qt > $JOIN_S;
                my $n = $Q->{ci_nonce};
                return ($S->{disp}{$n}, 'ci') if defined $n && $S->{disp}{$n} && !$jd{$n};
            }
        }
        return (undef, undef) unless defined $ref_t;
        my ($best, $bd);
        for my $D (@{ $S->{disp_list} }) {
            my $dt = _t($D) // next;
            next if $jd{ $D->{nonce} } || $dt > $ref_t + 1 || $ref_t - $dt > $JOIN_S;
            my $is_pre = ($D->{trigger} // '') eq 'precompute';
            next if $want_pre ? !$is_pre : $is_pre;
            if (!defined $bd || $ref_t - $dt < $bd) { $best = $D; $bd = $ref_t - $dt }
        }
        return $best ? ($best, 'time') : (undef, undef);
    };
    # 0.1.4: the PostCompact-only records of earlier Stops (session state `ponly`: the row's key, the
    # dispatch it took, its time, actor and record id). When the sweep lags behind the hooks, the
    # boundary of such a compaction is swept at a later Stop: it joins that record (the same nonce,
    # by core's compaction_boundary or rollup row naming the boundary's uuid, or the PostCompact row
    # within JOIN_S after the boundary), keeps its dispatch and its id, so the compaction stays one
    # record and its alerts are not raised twice.
    my @ponly = grep { ref $_ eq 'HASH' && defined $_->{k} && defined $_->{id} } @{ ref $sess->{ponly} eq 'ARRAY' ? $sess->{ponly} : [] };
    my (%uuid_nonce, @ponly_new);
    for my $r (values %{ $S->{boundary} || {} }, values %{ $S->{rollup} || {} }) {
        next unless defined $r->{boundary_uuid} && !ref $r->{boundary_uuid} && defined $r->{nonce} && !ref $r->{nonce};
        $uuid_nonce{ $r->{boundary_uuid} } //= $r->{nonce};
    }
    my %post_by = map { (_pkey($_) => $_) } @post;
    my $find_ponly = sub {
        my ($B) = @_;
        my $ba = $B->{actor} // 'main';
        my @c = grep { !$_->{used} && $post_by{ $_->{k} } } @ponly;
        @c = grep { my $pa = $_->{a} // 'unattributed'; $pa eq 'unattributed' || $pa eq 'unknown' || ($ba eq 'main' ? $pa eq 'main' : $pa ne 'main') } @c;
        my $bn = defined $B->{uuid} && !ref $B->{uuid} ? $uuid_nonce{ $B->{uuid} } : undef;
        if (defined $bn) { my ($po) = grep { ($_->{n} // '') eq $bn } @c; return $po if $po }
        return undef unless defined $B->{ts_epoch};
        my ($best, $bd);
        for my $po (@c) {
            next unless defined $po->{t};
            my $d = $po->{t} - $B->{ts_epoch};
            next if $d < -1 || $d > $JOIN_S;
            if (!defined $bd || abs($d) < $bd) { $best = $po; $bd = abs($d) }
        }
        return $best;
    };
    my $mk = sub {
        my ($B, $P, $po) = @_;
        my $ref_t = $B ? $B->{ts_epoch} : _t($P);
        my ($D, $join);
        if ($po) {
            $D = defined $po->{n} ? $S->{disp}{ $po->{n} } : undef;
            $join = $D ? $po->{j} : undef;
        } else {
            ($D, $join) = $find_disp->($P, $ref_t, $B && ${ $B->{precomputed} });
            $jd{ $D->{nonce} } = 1 if $D;
        }
        $jp{ _pkey($P) } = 1 if $P;
        my $C = { B => $B, P => $P, D => $D, join => $join };
        _derive($ctx, $S, $C);
        if ($po) { $C->{id} = $po->{id}; $C->{joined} = 1 }
        push @ponly_new, { k => _pkey($P), n => ($D ? $D->{nonce} : undef), j => $join, t => _t($P), a => $C->{actor}, id => $C->{id} }
            if $P && !$B;
        push @out, $C;
    };
    for my $B (sort { ($a->{ts_epoch} // 0) <=> ($b->{ts_epoch} // 0) } @$boundaries) {
        tick($ctx);
        my ($P, $pd, $po);
        if (defined $B->{ts_epoch}) {
            for my $p (@post) {
                next if $jp{ _pkey($p) };
                my $pt = _t($p) // next;
                my $d = abs($pt - $B->{ts_epoch});
                next if $d > $JOIN_S;
                if (!defined $pd || $d < $pd) { $P = $p; $pd = $d }
            }
        }
        if (!$P && ($po = $find_ponly->($B))) {
            $po->{used} = 1;
            $P = $post_by{ $po->{k} };
        }
        $mk->($B, $P, $po);
    }
    for my $p (@post) {
        next if $jp{ _pkey($p) };
        my $pt = _t($p) // next;
        next if $ctx->{now} - $pt <= $JOIN_S;
        tick($ctx);
        $mk->(undef, $p);
    }
    my @keep = ((grep { !$_->{used} } @ponly), @ponly_new);
    delete $_->{used} for @keep;
    @keep = @keep[-50 .. -1] if @keep > 50;
    if (@keep) { $sess->{ponly} = \@keep } else { delete $sess->{ponly} }
    my @jp = sort keys %jp;
    @jp = @jp[-300 .. -1] if @jp > 300;
    $sess->{jp} = \@jp;
    my @jd = sort keys %jd;
    @jd = @jd[-300 .. -1] if @jd > 300;
    $sess->{jd} = \@jd;
    return \@out;
}

sub _derive {
    my ($ctx, $S, $C) = @_;
    my ($B, $P, $D) = @$C{qw(B P D)};
    # Attribution.
    my $actor;
    if ($P && ($P->{scope_found} // '') eq 'sub' && $D && defined $D->{agent_id}) { $actor = $D->{agent_id} }
    elsif ($B) { $actor = $B->{actor} }
    elsif ($D && defined $D->{agent_id}) { $actor = $D->{agent_id} }
    elsif ($D && ($D->{actor} // '') eq 'main' && ($D->{channel} // '') =~ /\Amod-/) { $actor = 'main' }
    else { $actor = 'unattributed' }
    # A reconcile fill (copy_attributed, by id6) names the agent of a copy saved as
    # `sub-unknown`; it never turns a main compaction into a subagent one.
    my $rk0 = $D ? $D->{nonce} : $P ? $P->{nonce_found} : undef;
    my $id6 = (defined $rk0 && $S->{rollup}{$rk0}) ? $S->{rollup}{$rk0}{id6} : undef;
    $id6 //= $D->{id6} if $D;
    my $att = defined $id6 ? $S->{attributed}{$id6} : undef;
    if ($att && defined $att->{actor} && !ref $att->{actor} && $actor ne 'main') {
        $actor = $att->{actor};
        $C->{actor_src} = 'copy_attributed';
    }
    $C->{copy_path} = $att->{rel_path} if $att && defined $att->{rel_path};
    $C->{id6} = $id6;
    $C->{actor} = $actor;
    $C->{main} = $actor eq 'main' ? 1 : 0;
    $C->{precompute} = (($B && ${ $B->{precomputed} }) || ($D && ($D->{trigger} // '') eq 'precompute')) ? 1 : 0;
    # Trigger.
    my $trig;
    if ($D && ($D->{channel} // '') eq 'mod-self') { $trig = 'plugin' }
    elsif ($D && ($D->{channel} // '') ne 'classic' && defined $D->{trigger}) { $trig = $D->{trigger} }
    elsif ($B && defined $B->{boundary_trigger}) { $trig = $B->{boundary_trigger} }
    elsif ($P) { $trig = $P->{trigger} }
    $C->{trigger} = $trig;
    $C->{trigger_src} = !defined $trig ? undef
                      : ($D && (($D->{channel} // q()) eq q(mod-self) || (($D->{channel} // q()) ne q(classic) && defined $D->{trigger}))) ? q(dispatch)
                      : ($B && defined $B->{boundary_trigger}) ? q(boundary) : q(postcompact);
    $C->{nonce} = $D ? $D->{nonce} : ($P && $P->{nonce_found}) ? $P->{nonce_found} : 'none';
    $C->{nonce_match} = ($P && $D && defined $P->{nonce_found} && $P->{nonce_found} eq $D->{nonce}) ? 1 : 0;
    $C->{channel} = $D ? $D->{channel} : ($P ? 'none' : undef);
    # Verdict, with what the sweep adds: precomputed and attribution.
    my $v = $P ? $P->{verdict} : undef;
    if ($B && ${ $B->{precomputed} }) { $v = 'stale' }
    elsif ($P && $actor ne 'main' && $actor ne 'unattributed') {
        $v = 'scope-leak' if ($P->{scope_found} // '') eq 'main'
                          || (($P->{main_headings} // 0) > 0 && ($P->{scope_found} // '') ne 'sub');
    } elsif ($P && $actor eq 'main' && ($P->{scope_found} // '') eq 'sub') {
        $v = 'scope-leak';
    }
    $C->{verdict} = $v;
    $C->{key} = { session_id => $ctx->{sid}, actor => $actor,
                  compaction_seq => ($B ? $B->{seq} : undef), nonce => $C->{nonce} };
    $C->{id} = $B ? ('b:' . ($B->{uuid} // $B->{line})) : ('p:' . _pkey($P));
    # Copy.
    my $copy;
    my $rk = $D ? $D->{nonce} : $P ? $P->{nonce_found} : undef;
    # Sizes: the swept boundary first; without one, the rollup row joined with core's
    # `compaction_boundary` row by nonce (join_rollup).
    my $roll = defined $rk ? $S->{rollup}{$rk} : undef;
    $C->{pre} = ($B && defined $B->{pre}) ? $B->{pre} : $roll ? $roll->{pre_tokens} : undef;
    $C->{pre_src} = !defined $C->{pre} ? undef : ($B && defined $B->{pre}) ? 'transcript' : 'rollup';
    $C->{join_conflict} = $roll->{_join_conflict} if $roll && $roll->{_join_conflict};
    my $pc = $roll ? $roll->{precomputed} : undef;
    $pc = $$pc if ref $pc eq q(SCALAR);
    $C->{precompute} = 1 if !$B && $pc;
    if ($roll) {
        $C->{idle} = rollup_idle($roll);
        $C->{idle_source} = $roll->{idle_source} if defined $roll->{idle_source} && !ref $roll->{idle_source};
    }
    $C->{ref_t} = $P ? _t($P) : $B ? $B->{ts_epoch} : undef;
    $copy = copy_of($S, $rk, $C->{ref_t});
    $C->{copy} = $copy;
    $C->{copy_bad} = copy_bad($copy);
    # Liveness.
    if ($P) {
        my $modd = $D && ($D->{channel} // '') =~ /\Amod-/;
        my $self = grep { ($_->{channel} // '') eq 'mod-self' && defined _t($_) && defined _t($P)
                          && _t($P) - _t($_) >= 0 && _t($P) - _t($_) <= $JOIN_S } @{ $S->{disp_list} };
        if (!$modd && !$self) {
            if ($P->{mod_alive_this_turn}) { $C->{bypass_suspected} = 1 } else { $C->{mod_off} = 1 }
        }
    }
    # The realtime per-compaction fields ride on the boundary's sweep record.
    if ($B) {
        $B->{trigger} = $C->{trigger};
        $B->{trigger_src} = $C->{trigger_src};
        $B->{verdict} = $C->{verdict};
        $B->{nonce} = $C->{nonce};
        $B->{nonce_match} = watch::ctx::B($C->{nonce_match});
        $B->{channel} = $C->{channel};
        $B->{join} = $C->{join};
        $B->{attributed} = $C->{actor};
        $B->{copy} = $C->{copy};
        $B->{bypass_suspected} = watch::ctx::B($C->{bypass_suspected});
        $B->{mod_off} = watch::ctx::B($C->{mod_off});
        $B->{postcompact} = watch::ctx::B($P);
        # idle: from the rollup row (mod OR the native notice, settled at
        # reconcile); an idle compaction arrives as trigger `auto`.
        $B->{idle} = $C->{idle};
        $B->{idle_source} = $C->{idle_source};
    }
}

# copy_of(S, nonce, time) -> the compaction's copy: the rollup row's, else the copy rows
# by nonce (by time within JOIN_S without one), else a failed, exists or mismatch row; `missing`.
# 0.1.4: a rollup copy that says failed or missing (PostCompact's save failed and kept the stash)
# gives way to a saved, exists or late copy row of the same compaction (the later save; reconcile
# writes no second rollup row), else it stands.
sub copy_of {
    my ($S, $rk, $ref_t) = @_;
    my $rc = (defined $rk && $S->{rollup}{$rk}) ? $S->{rollup}{$rk}{copy} : undef;
    $rc = undef if ref $rc;
    return $rc if defined $rc && !copy_bad($rc);
    my $copy;
    for my $r (rows_of($S, 'copy')) {
        my $hit = defined $rk && defined $r->{nonce} ? $r->{nonce} eq $rk
                : (!defined $rc && defined $ref_t && defined _t($r) && abs(_t($r) - $ref_t) <= $JOIN_S);
        next unless $hit;
        $copy = $r->{result};
        return $copy if defined $copy && $copy =~ /\A(?:saved|exists|late)\z/;
    }
    return $rc if defined $rc;
    return $copy if defined $copy;
    for my $ev (qw(copy_failed copy_exists copy_mismatch)) {
        for my $r (rows_of($S, $ev)) {
            next unless defined $rk && ($r->{nonce} // '') eq $rk;
            $copy = $ev eq 'copy_failed' ? 'failed:' . ($r->{reason} // 'unknown') : $ev eq 'copy_exists' ? 'exists' : 'mismatch';
        }
    }
    return $copy // 'missing';
}
sub copy_bad { my ($copy) = @_; return ($copy eq 'missing' || $copy =~ /\Afailed/ || $copy eq 'not-found') ? 1 : 0 }

# rollup_idle(rollup row) -> its idle as `true`, `false` or `unknown`, else undef.
sub rollup_idle {
    my ($roll) = @_;
    return undef unless ref $roll eq 'HASH';
    my $iv = $roll->{idle};
    $iv = ($$iv ? 'true' : 'false') if ref $iv eq 'SCALAR';
    return (defined $iv && !ref $iv && $iv =~ /\A(?:true|false|unknown)\z/) ? $iv
         : (defined $iv && !ref $iv && $iv eq '1') ? 'true' : (defined $iv && !ref $iv && $iv eq '0') ? 'false' : undef;
}

# --- rules ------------------------------------------------------------------

sub evaluate {
    my ($ctx, $S, $ex, $sess, $sweep_files) = @_;
    my @bounds = map { @{ $_->{boundaries} } } @$sweep_files;
    my @events = map { @{ $_->{events} } } grep { $_->{actor} eq 'main' } @$sweep_files;
    my $C = build_compactions($ctx, $S, $sess, \@bounds);
    # the largest context a main boundary of the session showed (tokens before), kept across Stops
    for my $b (@bounds) {
        my $pre = ($b->{actor} // '') eq 'main' ? _num($b->{pre}) : undef;
        $sess->{ctx_seen} = int $pre if defined $pre && $pre > ($sess->{ctx_seen} // 0);
    }
    my $th = thresholds($ctx, $S, $sess->{ctx_seen});
    my $secret_class = watch::spec::secret_classes($ctx->{spec});
    my $vh = $sess->{vh} ||= [];
    my $prev_chars = $sess->{prev_chars} ||= {};
    my $R = sub { watch::alerts::raise($ctx, $ex, @_) };
    # 0.1.4: a rule is graded info when an open row of it exists (a closed one demotes nothing)
    my $once = sub { my $rule = shift; return ($ex->{open_by_rule}{$rule} // 0) ? q(info) : q(warn) };
    # A-23 of the idle compactions held at earlier Stops (below), before this Stop's own.
    my $held = _a23_held($ctx, $S, $sess, $R);
    my $a01_held = _a01_held($ctx, $S, $sess, $R);
    # A session with no row yet: this Stop is the plugin's first hook in it (installed or reloaded
    # mid-session), so its own start is where observing began.
    my $obs = observed_from($ctx) // $ctx->{now};
    local $ctx->{_obs} = $obs;

    for my $c (@$C) {
        tick($ctx);
        my ($B, $P, $D) = @$c{qw(B P D)};
        my @idp = ($c->{id});
        my %k = (key => $c->{key}, actor => $c->{actor});
        my $main_nf = $c->{main} && !$c->{precompute};
        # 0.1.3 alert noise: a boundary from before this session's first hook row (observed_from;
        # history the sweep reads from offset 0: a session already running at the install, or
        # resumed or forked after it) with no hook row or dispatch of its own was never
        # observed, so it raises no A-01, A-05 or hookless A-15.
        my $hist = $B ? history_boundary($B->{ts_epoch}, $P, $D, $obs) : 0;
        my $idle = idle_compaction($S, $c);
        # 0.1.4 (A-27): what a later continue needs to know of a main boundary, kept for the Stops after
        # this one (session state `bmeta`, by uuid: history boundary, idle)
        if ($B && $c->{main} && defined $B->{uuid} && !ref $B->{uuid}) {
            $sess->{bmeta}{ $B->{uuid} } = { t => $B->{ts_epoch}, hist => ($hist ? 1 : 0), idle => ($idle ? 1 : 0) };
        }
        if ($main_nf && $c->{copy_bad} && !$hist) {
            my $a01 = { id => $c->{id}, key => $c->{key}, actor => $c->{actor}, nonce => ($D ? $D->{nonce} : $P ? $P->{nonce_found} : undef),
                        t => $c->{ref_t}, line => ($B ? $B->{line} : undef) };
            my $stash = $c->{copy} eq 'missing' ? _stash_waits($ctx, $a01->{nonce}, $c->{id6}) : undef;
            if (defined $stash) { $a01->{stash} = $stash; push @$a01_held, $a01 }
            else { _a01($R, $a01, $c->{copy}) }
        }
        if ($c->{main} && defined $c->{verdict}) {
            my $bad = $BADV{ $c->{verdict} } ? 1 : 0;
            my $shaped = ($c->{channel} // '') =~ /\A(?:mod-hook|mod-self|classic)\z/;
            if ($bad && $shaped) {
                my $prev_bad = @$vh && $BADV{ $vh->[-1][1] // '' };
                $R->(rule => 'A-02', severity => ($prev_bad ? 'critical' : 'warn'), id_parts => \@idp, %k,
                     evidence => { verdict => $c->{verdict}, channel => $c->{channel}, join => $c->{join} });
            }
            if ($c->{joined}) {
                # a P-only record of an earlier Stop that its boundary joined: the same history entry
                $_->[0] = $B->{uuid} for grep { ($_->[0] // q()) eq $c->{id} && defined $B->{uuid} } @$vh;
            } elsif (!$c->{precompute}) {
                push @$vh, [ ($B ? $B->{uuid} : $c->{id}), $c->{verdict} ];
            }
            shift @$vh while @$vh > 20;
        }
        if (($c->{verdict} // '') eq 'scope-leak') {
            $R->(rule => 'A-03', severity => 'critical', id_parts => \@idp, %k,
                 evidence => { scope_found => ($P ? $P->{scope_found} : undef), line => ($B ? $B->{line} : undef),
                               file => ($B ? $B->{file} : undef) });
        }
        if ($P && ($P->{fabricated_check_tokens} // 0) > 0) {
            $R->(rule => 'A-04', severity => 'warn', id_parts => \@idp, %k,
                 evidence => { fabricated_check_tokens => $P->{fabricated_check_tokens}, measured => $P->{measured} });
        }
        # A-05 skips an idle compaction: it runs on the idle timer, not at a size, so its band
        # says nothing about the triggers.
        if ($c->{main} && !$B && !$c->{precompute} && ($c->{pre_src} // '') eq 'rollup') {
            # No swept boundary (the P-only path): the band from the joined rollup sizes.
            my $bp = band($th, $c->{pre});
            if (defined $bp && !$idle && ($c->{trigger} // '') eq 'auto' && $bp =~ /\A(?:above-softmax|at-native|below-target)\z/) {
                $R->(rule => 'A-05', severity => 'warn', id_parts => \@idp, %k,
                     evidence => { band_position => $bp, tokens_before => $c->{pre}, target => $th->{target},
                                   soft_max => $th->{soft_max}, native_trigger => $th->{native}, source => 'rollup' });
            }
        }
        if ($c->{main} && $B && !$c->{precompute}) {
            my $bp = band($th, $B->{pre});
            $B->{band_position} = $bp;
            if (defined $bp && !$idle && !$hist && ($c->{trigger} // '') eq 'auto' && $bp =~ /\A(?:above-softmax|at-native|below-target)\z/) {
                $R->(rule => 'A-05', severity => 'warn', id_parts => \@idp, %k,
                     evidence => { band_position => $bp, tokens_before => $B->{pre}, target => $th->{target},
                                   soft_max => $th->{soft_max}, native_trigger => $th->{native} });
            }
            my $ttl = $ctx->{settings}{cache_ttl_s};
            if (defined $B->{warm_gap_s} && $B->{warm_gap_s} > $ttl && ($B->{pre} // 0) >= 400000) {
                $R->(rule => 'A-06', severity => 'warn', id_parts => \@idp, %k,
                     evidence => { warm_gap_s => $B->{warm_gap_s}, tokens_before => $B->{pre} });
            }
            if (($B->{rapid_refill_run} // 0) >= 3) {
                $R->(rule => 'A-07', severity => 'critical', id_parts => \@idp, %k,
                     evidence => { rapid_refill_run => $B->{rapid_refill_run}, turns_since_prev => $B->{turns_since_prev} });
            }
            if (ref $B->{sid_canary} && !${ $B->{sid_canary} }) {
                $R->(rule => 'A-13', severity => 'critical', id_parts => \@idp, %k, evidence => { line => $B->{line} });
            }
        }
        if ($P && ref $P->{ledger} eq 'HASH') {
            my $l = $P->{ledger};
            my $u = $l->{lost_U} // 0;
            my $dx = ($l->{lost_D} // 0) + ($l->{lost_X} // 0);
            if ($u > 0 || $dx > 0) {
                $R->(rule => 'A-09', severity => ($u > 0 ? 'critical' : 'warn'), id_parts => \@idp, %k,
                     evidence => { lost_U => $l->{lost_U}, lost_D => $l->{lost_D}, lost_X => $l->{lost_X},
                                   renumbered => $l->{renumbered}, carried => $l->{carried}, ledger_src => $l->{ledger_src} });
            }
        }
        if ($P && defined $P->{summary_chars}) {
            my $slot = $c->{main} ? 'main' : 'sub';
            my $prev = $prev_chars->{$slot};
            if ($prev && $P->{summary_chars} / $prev > 1.5 && $P->{summary_chars} > 10000) {
                $R->(rule => 'A-10', severity => 'warn', id_parts => \@idp, %k,
                     evidence => { growth_ratio => int(100 * $P->{summary_chars} / $prev) / 100,
                                   summary_chars => $P->{summary_chars} });
            }
            $prev_chars->{$slot} = $P->{summary_chars};
        }
        if ($B && !$hist && (!$P && !_pre_near($S, $B->{ts_epoch}))) {
            $R->(rule => 'A-15', severity => $once->('A-15'), id_parts => [@idp, 'hookless'], %k,
                 evidence => { hookless_boundary => \1, line => $B->{line} });
        }
        if ($B && defined $B->{boundary_trigger} && $B->{boundary_trigger} !~ /\A(?:auto|manual)\z/) {
            $R->(rule => 'A-15', severity => $once->('A-15'), id_parts => [@idp, 'trigger'], %k,
                 evidence => { trigger_unknown => \1, line => $B->{line} });
        }
        if ($P && $P->{arm_new}) {
            $R->(rule => 'A-15', severity => $once->('A-15'), id_parts => [@idp, 'arm'], %k,
                 evidence => { arm_fp => $P->{arm_fp} });
        }
        # A-16: a subagent's compaction can set off bypass_suspected too.
        # Classic payloads carry no agent id, so a row for a compaction not proven main has
        # `actor: unknown` (the alert text says "possibly in a subagent").
        if ($c->{bypass_suspected} && !$c->{precompute}) {
            $R->(rule => 'A-16', severity => $once->('A-16'), id_parts => \@idp, %k,
                 actor => ($c->{main} ? 'main' : 'unknown'),
                 evidence => { bypass_suspected => \1, channel => $c->{channel}, main => watch::ctx::B($c->{main}) });
        }
        if ($P && @{ $P->{secret_hits} || [] }) {
            my @hard = grep { ($secret_class->{$_} // '') eq 'HARD' } @{ $P->{secret_hits} };
            if (@hard) {
                $R->(rule => 'A-21', severity => 'critical', id_parts => \@idp, %k, evidence => { rules => \@hard });
            }
        }
        if ($c->{main} && !$c->{precompute} && $c->{nonce} ne 'none') {
            my $a23 = { nonce => $c->{nonce}, id => $c->{id}, key => $c->{key}, actor => $c->{actor}, verdict => $c->{verdict} };
            my @inj = _injects($S, $c->{nonce});
            if (!@inj && _idle_dispatch($D) && _block_waits($ctx, $c->{nonce})) {
                push @$held, $a23 unless grep { $_->{nonce} eq $c->{nonce} } @$held;
            } else {
                _a23($R, $a23, \@inj, watch::spec::ok_verdicts($ctx->{spec}));
            }
        }
        if ($c->{main} && ($c->{mod_off} || ($P && ($c->{channel} // '') eq 'none'))) {
            $R->(rule => 'A-26', severity => $once->('A-26'), id_parts => \@idp, %k,
                 evidence => { mod_off => watch::ctx::B($c->{mod_off}), channel => $c->{channel} });
        }
    }
    if (ref $sess->{bmeta} eq q(HASH) && keys %{ $sess->{bmeta} } > $BMETA_MAX) {
        my $bm = $sess->{bmeta};
        my @k = sort { ((ref $bm->{$a} eq q(HASH) ? $bm->{$a}{t} : 0) // 0) <=> ((ref $bm->{$b} eq q(HASH) ? $bm->{$b}{t} : 0) // 0) } keys %$bm;
        delete @{$bm}{ @k[0 .. $#k - $BMETA_MAX] };
    }
    @$held = @$held[-$A23_HELD_MAX .. -1] if @$held > $A23_HELD_MAX;
    if (@$held) { $sess->{a23_held} = $held } else { delete $sess->{a23_held} }
    @$a01_held = @$a01_held[-$A23_HELD_MAX .. -1] if @$a01_held > $A23_HELD_MAX;
    if (@$a01_held) { $sess->{a01_held} = $a01_held } else { delete $sess->{a01_held} }
    _a01_resolved($ctx, $S, $ex);
    tick($ctx);
    _event_rules($ctx, $S, $ex, $sess, \@events, $C);
    tick($ctx);
    _session_rules($ctx, $S, $ex, $sess);
    return $C;
}

# --- A-23 and the idle block ---------------------------------------------------
#
# An idle compaction sends no continue: its resume block waits on disk for the next turn (the
# person's return, a background result, or the first turn of the next process of this session
# id, resume-persist), and only `prompt.context` delivers it. So a main Stop can sweep an idle
# compaction whose block nobody has claimed yet, and is still due to: that is not a missing
# block. Such a compaction is held (session state `a23_held`, at most $A23_HELD_MAX, the oldest
# dropped first) and decided at a later Stop: once a `resume_inject` row names its nonce, by the
# usual A-23 checks on those rows; once the block no longer waits with no claim (the mod settled
# it undelivered, a newer compaction replaced it, a /clear dropped it), as count 0. One that waits
# forever (the process stopped and the session never resumed) raises nothing.

sub _injects {
    my ($S, $nonce) = @_;
    return grep { ($_->{nonce} // '') eq $nonce } rows_of($S, 'resume_inject');
}

# One A-23 per reason for a compaction (`id`, `key`, `actor`, `verdict`) and its resume_inject rows.
sub _a23 {
    my ($R, $a, $inj, $okv) = @_;
    my @inj = @$inj;
    my $nonok = defined $a->{verdict} && !$okv->{ $a->{verdict} };
    my %why;
    $why{count} = scalar @inj if @inj == 0 || @inj >= 2;
    $why{nonok_note_missing} = \1 if $nonok && grep { defined $_->{nonok_note} && !$_->{nonok_note} } @inj;
    $why{resume_over_10k} = \1 if grep { ($_->{bytes} // 0) > 10000 } @inj;
    for my $w (sort keys %why) {
        $R->(rule => 'A-23', severity => 'warn', id_parts => [$a->{id}, $w], key => $a->{key}, actor => $a->{actor},
             evidence => { $w => $why{$w} });
    }
}

# An idle dispatch whose block goes by `prompt.context` (every idle mod dispatch since the P4 fix).
sub _idle_dispatch {
    my ($D) = @_;
    return 0 unless $D;
    my $i = $D->{idle};
    $i = $$i if ref $i eq 'SCALAR';
    return 0 unless defined $i && !ref $i && ($i eq '1' || $i eq 'true');
    return ($D->{resume_pref} // '') eq 'prompt.context' ? 1 : 0;
}

# The block of this nonce still waits: no claim, and the mod's record of it (resume-pending.json,
# or resume-armed.json once a resume armed it) is still pending.
sub _block_waits {
    my ($ctx, $nonce) = @_;
    my $d = watch::ctx::sid_dir($ctx);
    return 0 if -e "$d/resume-claimed/$nonce";
    for my $f (qw(resume-pending.json resume-armed.json)) {
        next if -l "$d/$f";
        my $j = watch::io::read_json_file("$d/$f");
        next unless ref $j eq 'HASH';
        return 1 if ($j->{state} // '') eq 'pending' && ($j->{nonce} // '') eq $nonce;
    }
    return 0;
}

# The compactions held at earlier Stops: each one decided now goes (A-23 as above), the rest
# come back in their order.
sub _a23_held {
    my ($ctx, $S, $sess, $R) = @_;
    my @keep;
    for my $h (@{ ref $sess->{a23_held} eq 'ARRAY' ? $sess->{a23_held} : [] }) {
        next unless ref $h eq 'HASH' && defined $h->{nonce} && !ref $h->{nonce};
        tick($ctx);
        my @inj = _injects($S, $h->{nonce});
        if (!@inj && _block_waits($ctx, $h->{nonce})) { push @keep, $h; next }
        _a23($R, $h, \@inj, watch::spec::ok_verdicts($ctx->{spec}));
    }
    return \@keep;
}

# --- A-01 and a copy reconcile left for the next Stop (0.1.3) ------------------
#
# A Stop that starts late leaves a main-proven save to the next Stop (lib/reconcile.pm
# SWEEP_MIN_MS): its stash stays in pending/, and the copy is not missing, only late. Such a
# compaction's A-01 is held (session state `a01_held`, at most $A23_HELD_MAX) while its stash
# is still in pending/ and reconcile still waits on it (a run out of budget leaves the stashes it
# did not reach the same way); a later Stop that finds the copy drops it, one whose reconcile no
# longer waits on the stash (a failed save, no stash left, a refused handoff_root) raises it. The
# session's end does the same after its final reconcile (SessionEnd, or another session's
# cross-session finish: a01_end below), so a held A-01 is neither lost nor left open. An open A-01
# whose copy has since been saved is closed (`alert_closed`, reason `resolved: copy saved`; the
# row is kept).
our $RESOLVED = 'resolved: copy saved';

sub _a01 {
    my ($R, $a, $copy) = @_;
    $R->(rule => 'A-01', severity => 'critical', id_parts => [$a->{id}], key => $a->{key}, actor => $a->{actor},
         evidence => { copy => ($copy =~ /\Afailed/ ? 'failed' : $copy), line => $a->{line} });
}

# _stash_waits(ctx, nonce, id6) -> the stash file reconcile left in pending/ at this Stop for
# that compaction (ctx copy_waits, cmd/hook.pl), when it is still there; else undef. A stash
# reconcile did not reach is named by its file only: a marked summary's is the nonce's first 6.
# 0.1.4: when this run's reconcile could not take the session's reconcile lock (ctx
# reconcile_busy: a `reconcile` call or another session's finish held it, so it left no waits),
# any stash of that compaction still in pending/ (<nonce>.mod.md, <id6 or the nonce's first 6>.post.md)
# is waited on: the lock holder works on it.
sub _stash_waits {
    my ($ctx, $nonce, $id6) = @_;
    my $n6 = (defined $nonce && !ref $nonce && $nonce =~ /\A([0-9a-f]{6})[0-9a-f]{2}\z/) ? $1 : undef;
    if ($ctx->{reconcile_busy}) {
        my $d = watch::ctx::sid_dir($ctx) . '/pending';
        for my $f ((defined $n6 ? "$nonce.mod.md" : ()), map { defined $_ && !ref $_ && /\A[0-9a-z-]{6,12}\z/ ? "$_.post.md" : () } $id6, $n6) {
            return $f if -f "$d/$f";
        }
    }
    my $w = ref $ctx->{copy_waits} eq 'HASH' ? $ctx->{copy_waits} : return undef;
    for my $k ((defined $nonce && !ref $nonce ? "n:$nonce" : ()), map { defined $_ && !ref $_ ? "i:$_" : () } $id6, $n6) {
        my $f = $w->{$k};
        return $f if _waits_on($ctx, $f);
    }
    return undef;
}

# _waits_on(ctx, file) -> 1 when this run's reconcile left that stash waiting (or could not take
# the lock, reconcile_busy) and it is still in pending/.
sub _waits_on {
    my ($ctx, $f) = @_;
    return 0 unless defined $f && !ref $f && $f =~ /\A[0-9A-Za-z._-]+\z/;
    return -f watch::ctx::sid_dir($ctx) . "/pending/$f" ? 1 : 0 if $ctx->{reconcile_busy};
    return 0 unless ref $ctx->{copy_waits} eq 'HASH';
    return 0 unless grep { defined $_ && !ref $_ && $_ eq $f } values %{ $ctx->{copy_waits} };
    return -f watch::ctx::sid_dir($ctx) . "/pending/$f" ? 1 : 0;
}

sub _a01_held {
    my ($ctx, $S, $sess, $R) = @_;
    my @keep;
    for my $h (@{ ref $sess->{a01_held} eq 'ARRAY' ? $sess->{a01_held} : [] }) {
        next unless ref $h eq 'HASH' && defined $h->{id} && !ref $h->{id};
        tick($ctx);
        my $copy = copy_of($S, $h->{nonce}, $h->{t});
        next unless copy_bad($copy);
        if ($copy eq 'missing' && _waits_on($ctx, $h->{stash})) { push @keep, $h; next }
        _a01($R, $h, $copy);
    }
    return \@keep;
}

sub _a01_resolved {
    my ($ctx, $S, $ex) = @_;
    for my $r (grep { ($_->{rule} // '') eq 'A-01' } @{ $ex->{open} || [] }) {
        next if exists $ex->{closed}{ $r->{alert_id} };
        my $nonce = ref $r->{key} eq 'HASH' ? $r->{key}{nonce} : undef;
        next unless defined $nonce && !ref $nonce && $nonce =~ /\A[0-9a-f]{8}\z/;
        next unless copy_of($S, $nonce, undef) =~ /\A(?:saved|exists|late)\z/;
        tick($ctx);
        watch::alerts::close_alert($ctx, $ex, $r, $RESOLVED);
    }
}

# a01_end(ctx, deadline) -> 1 when it ran: the session's end, after its final reconcile (ctx
# `reconcile`, that run's result with its `waits`; payload transcript_path names the session
# state). The held A-01s are checked as a Stop checks them and an open A-01 whose copy landed is
# closed; no other rule runs. Past the deadline (watch::io::mono) it stops with nothing kept.
sub a01_end {
    my ($ctx, $deadline) = @_;
    require watch::alerts;
    require watch::cache;
    require watch::sweep;
    local $ctx->{_deadline} = $deadline;
    my $rc = $ctx->{reconcile};
    local $ctx->{copy_waits} = (ref $rc eq 'HASH' && ref $rc->{waits} eq 'HASH') ? $rc->{waits} : {};
    local $ctx->{reconcile_busy} = (ref $rc eq 'HASH' && $rc->{busy}) ? 1 : 0;
    my $ex = watch::alerts::load_existing($ctx);
    my $open = grep { ($_->{rule} // '') eq 'A-01' } @{ $ex->{open} };
    my $ran = 0;
    watch::sweep::with_state($ctx, sub {
        my ($state) = @_;
        my $sess = (ref $state eq 'HASH' && ref $state->{session} eq 'HASH') ? $state->{session} : undef;
        my $held = ($sess && ref $sess->{a01_held} eq 'ARRAY' && @{ $sess->{a01_held} }) ? 1 : 0;
        return 0 unless $held || $open;
        my $cache = watch::cache::load($ctx, kinds => \@KINDS, deadline => $deadline);
        return 0 unless $cache->{complete};
        my $S = load_session($ctx, $cache);
        $ran = 1;
        _a01_resolved($ctx, $S, $ex);
        return 0 unless $held;
        my $keep = _a01_held($ctx, $S, $sess, sub { watch::alerts::raise($ctx, $ex, @_) });
        if (@$keep) { $sess->{a01_held} = $keep } else { delete $sess->{a01_held} }
        return 1;
    });
    return $ran;
}

sub _pre_near {
    my ($S, $t) = @_;
    return 1 unless defined $t;
    for my $r (rows_of($S, 'precompact'), rows_of($S, 'postcompact')) {
        return 1 if defined _t($r) && abs(_t($r) - $t) <= $JOIN_S;
    }
    return 0;
}

# observed_from(ctx) -> epoch of this session's first hook row, or undef when it has
# none yet: the time of the first row in its classic or mod stream, whichever is earliest,
# leaving out the rows the Stop writes itself (sweep, sweep_partial, watch_error,
# precompute_or_failed, and the stop_timing row it writes last, cmd/hook.pl); not the rollup, whose rows carry the compaction's own time when
# reconcile writes them late. The plugin writes a session's rows from its first hook on
# (SessionStart writes before any compaction), so a boundary before that time ran while the
# plugin was not loaded in that process, or under a store this install does not read. Per
# session, not store-wide: Claude Code loads plugins when a process starts, so a session
# already running at the install compacts unobserved until it is resumed. The streams are
# append-only, so their first rows never change. 0.1.3: a session whose streams hold only the
# Stop's own rows (no SessionStart, mod or preamble row before its first plugin Stop, e.g. the
# plugin loaded mid-session on the classic path) is observed from the earliest of those rows:
# the first plugin Stop ran then, so what its sweep found before that is history too. With no
# row at all, that first Stop is the one running: evaluate takes its time (ctx now).
# 0.1.4: the rule lives in core (sessions::first_row), the one definition core's order canary
# (reconcile::cutoff) takes too; with no stream row it falls back to the alive files' time.
sub observed_from {
    my ($ctx) = @_;
    my $core = eval { require sessions; 1 };
    return $core ? sessions::first_row(watch::ctx::sid_dir($ctx), watch::ctx::classic_log($ctx), watch::ctx::mod_log($ctx)) : undef;
}

# history_boundary(boundary epoch, P, D, observed_from) -> 1 for a boundary from before the
# session's first hook row (observed_from) with no PostCompact row and no dispatch of its own:
# the plugin never observed that compaction (0.1.3 alert noise: no A-01, A-05 or hookless A-15).
# P and D are anything true when present (the rows, or the flags a sweep record keeps).
sub history_boundary {
    my ($bt, $P, $D, $obs) = @_;
    return ($P || $D || !defined $obs || !defined $bt || $bt >= $obs) ? 0 : 1;
}

# idle_compaction(S, compaction) -> 1 for an idle compaction: the rollup's settled idle (mod
# OR the native notice), or the mod's dispatch record says idle. A swept boundary
# whose dispatch an earlier P-only record already took (the sweep lagged behind the hooks in a
# long transcript) has no D of its own: a main mod dispatch marked idle from $JOIN_S before
# it to 1 s after it is that compaction's.
#
# 0.1.4: a boundary the sweep marked with Claude Code's native idle notice (`idle_notice`: the
# first "Compacted while idle" or "... written while you were away" row after it; the rule
# reconcile settles the rollup idle by) is idle too, with no dispatch and before reconcile ran.
sub idle_compaction {
    my ($S, $c) = @_;
    return 1 if ($c->{idle} // '') eq 'true';
    return 1 if ref $c->{B} eq 'HASH' && defined $c->{B}{idle_notice} && !ref $c->{B}{idle_notice} && $c->{B}{idle_notice} =~ /\A(?:notice|return)\z/;
    my $yes = sub { my $i = shift; $i = $$i if ref $i eq 'SCALAR'; return (defined $i && !ref $i && ($i eq '1' || $i eq 'true')) ? 1 : 0 };
    return $yes->($c->{D}{idle}) if $c->{D};
    my $t = $c->{B} ? $c->{B}{ts_epoch} : undef;
    return 0 unless defined $t;
    for my $D (@{ $S->{disp_list} }) {
        my $dt = _t($D) // next;
        next if $dt > $t + 1 || $t - $dt > $JOIN_S;
        next unless ($D->{channel} // '') =~ /\Amod-/ && !defined $D->{agent_id} && ($D->{trigger} // '') ne 'precompute';
        return 1 if $yes->($D->{idle});
    }
    return 0;
}

sub _event_rules {
    my ($ctx, $S, $ex, $sess, $events, $C) = @_;
    my $okv = watch::spec::ok_verdicts($ctx->{spec});
    my $R = sub { watch::alerts::raise($ctx, $ex, @_) };
    my $vh = $sess->{vh} || [];
    # A-12: an outward call after a boundary or a manual resume is consented
    # by a later human-typed row (the sweep's window consent) or by an approval checked for that
    # window: a class in the approvals_checked of a dispatch row or the classes of an
    # approvals_carry row (`measure` on the handoff or on the summary's copy) logged between the
    # window's start (less $JOIN_S: the after-step measures near the boundary row) and the call.
    # An explicit-gate class (spec explicit_gate_classes) is never consented by an approval.
    my $gl = (ref $ctx->{spec} eq 'HASH' && ref $ctx->{spec}{explicit_gate_classes} eq 'ARRAY')
        ? $ctx->{spec}{explicit_gate_classes} : [qw(deploy env-write infra-write prod-write protected-push)];
    my %gate = map { $_ => 1 } grep { defined && !ref } @$gl;
    my @carry;
    for my $d (rows_of($S, 'dispatch'), rows_of($S, 'approvals_carry')) {
        my $l = ($d->{ev} // '') eq 'approvals_carry' ? $d->{classes} : $d->{approvals_checked};
        my %c = map { $_ => 1 } grep { defined && !ref && !$gate{$_} } @{ ref $l eq 'ARRAY' ? $l : [] };
        push @carry, [ _t($d), \%c ] if %c && defined _t($d);
    }
    my $approved = sub {
        my ($e) = @_;
        # A push the sweep saw going to a protected branch is the protected-push gate.
        return 0 if !@carry || $gate{ $e->{class} // '' } || ($e->{protected} && $gate{'protected-push'});
        # Event times are epochs (watch::rows::ts_of).
        my $t = _num($e->{ts}) // return 0;
        my $w = _num($e->{win_ts});
        for my $c (@carry) {
            next if $c->[0] > $t || (defined $w && $c->[0] < $w - $JOIN_S);
            return 1 if $c->[1]{ $e->{class} };
        }
        return 0;
    };
    my $max_cont = $ctx->{settings}{max_auto_continues_per_hour};
    my %kind = %{ $sess->{task_kinds} || {} };
    for my $slot (@{ $S->{bg} }) {
        for my $t (@{ $slot->{tasks} }) {
            $kind{ $t->{id} } = $t->{type} // $t->{kind} if defined $t->{id};
        }
    }
    for my $e (@$events) {
        tick($ctx);
        my $k = $e->{k};
        if ($k eq 'outward' && !$approved->($e)) {
            $R->(rule => 'A-12', severity => 'critical', id_parts => [$e->{win_uuid} // $e->{win_line}, $e->{class}, $e->{call_no}],
                 evidence => { class => $e->{class}, call_no => $e->{call_no}, line => $e->{line},
                               after => $e->{win_kind}, ($e->{win_kind} eq 'resume' ? (args_present => watch::ctx::B($e->{args})) : ()) });
        } elsif ($k eq 'sid_mismatch') {
            $R->(rule => 'A-13', severity => 'critical', id_parts => ['b:' . ($e->{b_uuid} // '')],
                 evidence => { line => $e->{line} });
        } elsif ($k eq 'slow_progress') {
            $R->(rule => 'A-14', severity => 'warn', id_parts => [$e->{b_uuid}], evidence => { batches => $e->{batches}, line => $e->{line} });
        } elsif ($k eq 'nudge_unresolved') {
            $R->(rule => 'A-08', severity => 'warn', id_parts => [$e->{line}], evidence => { line => $e->{line} });
        } elsif ($k eq 'api_error' && $e->{class} =~ /\A(?:compact|thrash|prompt-too-long)\z/) {
            $R->(rule => 'A-17', severity => 'critical', id_parts => ['api', $e->{line}],
                 evidence => { failed => 'api-error:' . $e->{class}, line => $e->{line} });
            if ($e->{class} eq 'thrash') {
                $R->(rule => 'A-07', severity => 'critical', id_parts => ['native', $e->{line}],
                     evidence => { native_thrash => \1, line => $e->{line} });
            }
        } elsif ($k eq 'taskstop') {
            my $type = $kind{ $e->{stop_id} } // '';
            next unless $type =~ /workflow/i;
            my $healed = grep { ($_->{item} // '') eq $e->{stop_id} && ($_->{result} // '') =~ /\Aok/ } rows_of($S, 'heal');
            $R->(rule => 'A-20', severity => 'critical', id_parts => [$e->{win_uuid}, $e->{line}],
                 evidence => { line => $e->{line} }) unless $healed;
        } elsif ($k eq 'handoff_turn') {
            # the submit of this ht was swept; the Stop now running ends that turn or a later one.
            $sess->{ht_seen}{ $e->{ht} } = 1 if defined $e->{ht};
        } elsif ($k eq 'continue') {
            my $pos;
            if (defined $e->{b_uuid}) {
                for my $i (0 .. $#$vh) { $pos = $i if ($vh->[$i][0] // '') eq $e->{b_uuid} }
            }
            if (defined $pos && $pos >= 1 && !$okv->{ $vh->[$pos][1] // q() } && !$okv->{ $vh->[$pos - 1][1] // q() }) {
                $R->(rule => 'A-19', severity => 'critical', id_parts => ['halt', $e->{uuid} // $e->{line}],
                     evidence => { continue_after_halt_cond => \1, line => $e->{line} });
            }
            if ($max_cont == 0 && !rows_of($S, 'continue')) {
                $R->(rule => 'A-19', severity => 'critical', id_parts => ['cap0', $e->{uuid} // $e->{line}],
                     evidence => { cap => 0, line => $e->{line} });
            }
            # 0.1.4: no A-27 after a boundary the plugin never observed (a history boundary, as A-01,
            # A-05 and the hookless A-15 skip it; all 12 rows of the 0.1.2 log were such) or after an
            # idle compaction (it runs on the idle timer: no nudge comes before it)
            if (defined $e->{b_uuid} && !$e->{b_nudged} && !a27_quiet($ctx, $S, $sess, $e)) {
                $R->(rule => 'A-27', severity => 'warn', id_parts => [$e->{uuid} // $e->{line}],
                     evidence => { continue_without_nudge => \1, line => $e->{line} });
            }
        } elsif ($k eq 'heal_call') {
            for my $rc (rows_of($S, 'resume_receipt')) {
                my $rel = $rc->{relation} // '';
                next unless $rel eq 'unselected' || $rel eq 'other';
                next unless defined _t($rc) && defined $e->{ts} && $e->{ts} > _t($rc);
                $R->(rule => 'A-22', severity => ($rel eq 'unselected' ? 'critical' : 'warn'),
                     id_parts => [$rc->{ts}], evidence => { relation => $rel, line => $e->{line} });
            }
        }
    }
    for my $r (rows_of($S, 'continue')) {
        my $n = $r->{continues_last_hour};
        if (defined $n && !ref $n && $n =~ /\A[0-9]+\z/ && $n > $max_cont) {
            $R->(rule => 'A-19', severity => 'critical', id_parts => ['cap', $r->{ts}],
                 evidence => { continues_last_hour => 0 + $n, cap => $max_cont });
        }
    }
    for my $r (rows_of($S, 'thrash')) {
        $R->(rule => 'A-07', severity => 'critical', id_parts => ['mod', $r->{ts}], evidence => { mod_thrash => \1 });
    }
    # A-28: a compaction_cold row (the mod's prefix read under
    # its cold share; an older version's row has the read share of all input instead),
    # or a handoff turn whose first request read under $COLD_SHARE of its input
    # from the cache at >= $COLD_MIN_TOKENS (handoff_turn_end cache_read_share; the context size
    # from its handoff_turn_start t0): the request may have gone to another model than the
    # session's own.
    for my $r (rows_of($S, 'compaction_cold')) {
        my %ev = defined $r->{prefix_read} ? (prefix_read => _num($r->{prefix_read})) : (read_share => _num($r->{read_share}));
        $R->(rule => 'A-28', severity => 'warn', id_parts => ['compaction', $r->{nonce} // $r->{ts}],
             evidence => { %ev, kind => 'compaction' });
    }
    my %t0 = map { ($_->{ht} // '') => $_->{t0} } grep { defined $_->{ht} } rows_of($S, 'handoff_turn_start');
    for my $r (rows_of($S, 'handoff_turn_end')) {
        my $share = _num($r->{cache_read_share});
        next unless defined $share && $share < $COLD_SHARE;
        my $tok = _num($r->{t0}) // _num($t0{ $r->{handoff_ht} // '' });
        next unless defined $tok && $tok >= $COLD_MIN_TOKENS;
        $R->(rule => 'A-28', severity => 'warn', id_parts => ['handoff-turn', $r->{handoff_ht} // $r->{ts}],
             evidence => { read_share => $share, kind => 'handoff-turn' });
    }
    # A-29: an idle_unshaped row (reconcile: a "Compacted while idle" boundary
    # that no plugin dispatch shaped; native idle compaction ran on its own).
    for my $r (rows_of($S, 'idle_unshaped')) {
        $R->(rule => 'A-29', severity => 'warn', id_parts => [ 'b', $r->{boundary_uuid} // $r->{ts} ], evidence => {});
    }
}

# a27_quiet(ctx, S, sess, continue event) -> 1 when the continue's last main boundary is a history
# boundary or an idle compaction: by what evaluate kept of it (session state bmeta), else by the
# boundary time and idle notice the sweep put on the event (a boundary evaluated before 0.1.4:
# history when it is before the session's first row and no PostCompact row lies near it).
sub a27_quiet {
    my ($ctx, $S, $sess, $e) = @_;
    my $m = ref $sess->{bmeta} eq 'HASH' ? $sess->{bmeta}{ $e->{b_uuid} } : undef;
    return ($m->{hist} || $m->{idle}) ? 1 : 0 if ref $m eq 'HASH';
    return 1 if defined $e->{b_idle_notice} && !ref $e->{b_idle_notice} && $e->{b_idle_notice} =~ /\A(?:notice|return)\z/;
    my $bt = _num($e->{b_ts});
    return 0 unless defined $bt;
    my $obs = exists $ctx->{_obs} ? $ctx->{_obs} : ($ctx->{_obs} = observed_from($ctx));
    return history_boundary($bt, _pre_near($S, $bt) ? 1 : 0, 0, $obs);
}

sub _num { my ($v) = @_; return (defined $v && !ref $v && $v =~ /\A-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\z/) ? 0 + $v : undef }

sub _session_rules {
    my ($ctx, $S, $ex, $sess) = @_;
    my $R = sub { watch::alerts::raise($ctx, $ex, @_) };
    my $now = $ctx->{now};
    my $last_stop = $sess->{last_stop_ts};
    my $disp = $S->{disp};
    my $excluded = sub { my $d = shift; return !$d || ($d->{trigger} // '') eq 'precompute' || defined $d->{agent_id} };

    # A-17 (a) a skipped after-step, (b) a mod dispatch without `compacted` in 15 min. A
    # dispatch whose call Claude Code rejected as headless (`compact_rejected {error_class:
    # headless}`) is explained: Claude Code rejects a plugin's
    # compaction call in that session, so it is not a missing after-step. So is a headless
    # `/compact` the host cannot run (`compact_command {error_class: no-command|input-ended}`).
    my %compacted;
    for my $r (rows_of($S, 'compact_rejected')) {
        $compacted{ $r->{nonce} } = 1 if defined $r->{nonce} && !ref $r->{nonce} && ($r->{error_class} // '') eq 'headless';
    }
    for my $r (rows_of($S, 'compact_command')) {
        $compacted{ $r->{nonce} } = 1 if defined $r->{nonce} && !ref $r->{nonce} && ($r->{error_class} // '') =~ /\A(?:no-command|input-ended)\z/;
    }
    for my $r (rows_of($S, 'compacted')) {
        $compacted{ $r->{nonce} } = 1 if defined $r->{nonce};
        next unless defined $r->{skip} && !ref $r->{skip};
        # DP-29: the mod dropped its dispatch because a native compaction ran; the
        # row (with the nonce) closes that dispatch, so it is neither a skipped after-step (a)
        # nor a dispatch without `compacted` (b, the nonce is in %compacted above).
        # So for one dropped because a person's turn or prompt came first (`user-first`).
        next if $r->{skip} eq 'native-ran' || $r->{skip} eq 'user-first';
        my $rd = $disp->{ $r->{nonce} // q() };
        next if $rd && $excluded->($rd);
        $R->(rule => 'A-17', severity => 'critical', id_parts => ['skip', $r->{nonce} // $r->{ts}],
             evidence => { failed => "skipped:$r->{skip}" });
    }
    for my $d (@{ $S->{disp_list} }) {
        next unless ($d->{channel} // '') =~ /\Amod-/ && !$excluded->($d);
        next if $compacted{ $d->{nonce} } || !defined _t($d) || $now - _t($d) < 900;
        $R->(rule => 'A-17', severity => 'critical', id_parts => ['no-after', $d->{nonce}],
             key => { session_id => $ctx->{sid}, actor => 'main', compaction_seq => undef, nonce => $d->{nonce} },
             evidence => { failed => 'no-after' });
    }
    # A-17 (c): a PreCompact never followed by its PostCompact.
    my @pre = grep { defined _t($_) } rows_of($S, 'precompact');
    my @post = grep { defined _t($_) } rows_of($S, 'postcompact');
    my %paired;
    for my $p (@post) {
        my ($q) = grep { !$paired{$_} && _t($pre[$_]) <= _t($p) + 1 } reverse 0 .. $#pre;
        $paired{$q} = 1 if defined $q;
    }
    # One info row per PreCompact: the rows already in the stream count too, so
    # a run dropped at the hard stop (which keeps no session state) and
    # evaluated again writes none twice.
    my %pof = map { $_ => 1 } @{ $sess->{pof} || [] };
    $pof{ $_->{precompact_ts} } = 1 for grep { defined $_->{precompact_ts} } rows_of($S, 'precompute_or_failed');
    for my $i (0 .. $#pre) {
        next if $paired{$i};
        my $later = grep { $paired{$_} } ($i + 1 .. $#pre);
        next unless $later || $now - _t($pre[$i]) > 900;
        my $q = $pre[$i];
        my $n = $q->{ci_nonce};
        my $d = defined $n ? $disp->{$n} : undef;
        my $counts = ($q->{trigger} // '') eq 'manual' || ($d && !$excluded->($d));
        if ($counts) {
            $R->(rule => 'A-17', severity => 'critical', id_parts => ['no-post', $q->{ts}],
                 evidence => { failed => 'no-post', trigger => $q->{trigger} });
        } elsif (!$pof{ $q->{ts} // '' }) {
            $pof{ $q->{ts} // '' } = 1;
            watch::ctx::log_row($ctx, 'precompute_or_failed', { trigger => $q->{trigger}, precompact_ts => $q->{ts},
                                                                 ci_nonce => $n, join => 'none' }, actor => 'unknown');
        }
    }
    my @pof = sort keys %pof;
    @pof = @pof[-200 .. -1] if @pof > 200;
    $sess->{pof} = \@pof;
    tick($ctx);
    # A-17 (d): a StopFailure within 60 s of a counted dispatch. Core's hook
    # writes the one `stop_failure` row; the watcher reads it.
    for my $sf (rows_of($S, 'stop_failure')) {
        my $st = _t($sf) // next;
        my ($d) = grep { !$excluded->($_) && defined _t($_) && $st - _t($_) >= 0 && $st - _t($_) <= 60 } @{ $S->{disp_list} };
        next unless $d;
        $R->(rule => 'A-17', severity => 'critical', id_parts => ['stop-failure', $sf->{ts}],
             evidence => { failed => 'api-error:' . ($sf->{error_class} // 'other') });
    }
    # A-17 (f): >= 3 compact_rejected in one turn (since the previous Stop).
    my @rej = grep { !defined $last_stop || (_t($_) // 0) > $last_stop } rows_of($S, 'compact_rejected');
    if (@rej >= 3) {
        $R->(rule => 'A-17', severity => 'critical', id_parts => ['rejected', $rej[0]{ts}],
             evidence => { failed => 'rejected', count => scalar @rej });
    }
    # A-18: auto-continue stopped by a halt with no handoff written that turn, or in the
    # plugin-submitted handoff turn of the same ht (in a last cycle the handoff is
    # published in its own turn, after the nudged one). Nothing is raised while that outcome
    # is open: the handoff turn is still to come (no ht yet, inside the grace period, and the
    # mod has not said it skipped) or has not been seen finishing.
    my $handoff_on = lc($ctx->{settings}{handoff_turn} // 'halt') ne 'off';
    for my $r (rows_of($S, 'continue')) {
        next unless ($r->{result} // '') =~ /\Ahalt:/;
        my $rt = _t($r) // next;
        my $from = defined $last_stop && $last_stop < $rt ? $last_stop : $rt - 3600;
        my $ht = watch::hturn::opened_after($ctx, $rt);
        my $wrote = grep { ($_->{result} // '') =~ /\Awrote/ && defined _t($_) && _t($_) >= $from }
                    rows_of($S, 'handoff_publish');
        $wrote ||= ($ht && $ht->{published}) ? 1 : 0;
        $wrote ||= ($ht && grep { ($_->{result} // q()) =~ /\Awrote/ && ($_->{ht} // q()) eq $ht->{ht} } rows_of($S, q(handoff_publish))) ? 1 : 0;
        unless ($wrote) {
            my $settled;
            if ($ht) {
                $settled = $sess->{ht_seen}{ $ht->{ht} }
                    || grep { ($_->{ht} // '') eq $ht->{ht} } rows_of($S, 'handoff_user_interjected'), rows_of($S, 'handoff_skipped');
            } else {
                # A skip of an optional turn (pre-compaction `again`, any row with `reason:
                # precompact` or `idle`; last-cycle rows carry no
                # reason) says nothing about the last-cycle handoff turn.
                $settled = !$handoff_on
                    || ($ctx->{now} - $rt) >= $watch::hturn::OPEN_AFTER_ROW_S
                    || grep { defined _t($_) && _t($_) >= $rt - $watch::hturn::SKEW_S && _t($_) <= $rt + $watch::hturn::OPEN_AFTER_ROW_S
                              && ($_->{why} // '') ne 'again' && ($_->{reason} // '') !~ /\A(?:idle|precompact)\z/ }
                      rows_of($S, q(handoff_skipped));
            }
            next unless $settled;
        }
        $R->(rule => 'A-18', severity => 'warn', id_parts => [$r->{ts}], evidence => { result => $r->{result} })
            unless $wrote;
    }
    # A-14 (manual resume part).
    for my $r (rows_of($S, 'resume_receipt')) {
        next unless defined $r->{calls} && !ref $r->{calls} && $r->{calls} =~ /\A[0-9]+\z/ && $r->{calls} > 20;
        $R->(rule => 'A-14', severity => 'warn', id_parts => ['receipt', $r->{ts}], evidence => { calls => 0 + $r->{calls} });
    }
    # A-15 from canary rows.
    for my $ev (qw(keyset_change version_change trigger_unknown order_anomaly)) {
        for my $r (rows_of($S, $ev)) {
            my $first = !grep { ($_->{rule} // q()) eq q(A-15) && ($_->{cc_version} // q()) eq ($r->{cc_version} // q()) } @{ $ex->{open} };
            $R->(rule => 'A-15', severity => ($first ? 'warn' : 'info'), id_parts => [$ev, $r->{ts}],
                 evidence => { canary => $ev });
        }
    }
    tick($ctx);
    # A-24: quota warnings from the sweep; the watch dir over watch_quota_mb (default 50; 0 = off).
    for my $r (rows_of($S, 'warn_quota')) {
        $R->(rule => 'A-24', severity => 'warn', id_parts => ['quota', $r->{ts}], evidence => { mb => $r->{mb} });
    }
    # 0.1.4: the walk also runs while a watch-size A-24 is open (hourly, _watch_mb). A folder over
    # quota, or with more entries than the walk counts (WATCH_MB_CAP; its size is then a lower
    # bound), raises one A-24 per episode: its id carries the UTC date of the walk that first found
    # the folder over (session state `watch_ep`), so a rise after a close raises a new id (a closed
    # id is never raised again). A walk that finds the folder back under quota and under the cap
    # closes the open one (`resolved: below quota`) and ends the episode.
    {
        my @open = grep { ($_->{rule} // '') eq 'A-24' && ref $_->{evidence} eq 'HASH' && $_->{evidence}{watch_dir} } @{ $ex->{open} };
        my $w = _watch_mb($ctx, $sess);
        my $quota = $ctx->{settings}{watch_quota_mb} // 50;
        $quota = 10000 if $quota > 10000;
        if ($w && $quota > 0 && ($w->{over} || $w->{mb} > $quota)) {
            my $ep = $sess->{watch_ep} //= _utc_date($now);
            unless (@open) {
                $R->(rule => 'A-24', severity => 'warn', id_parts => ['watch-size', $ep],
                     evidence => { watch_dir => \1, ($w->{over} ? (mb_at_least => int $w->{mb}, entries_over => $WATCH_MB_CAP)
                                                                : (mb => int $w->{mb})) });
            }
        } elsif ($w) {
            delete $sess->{watch_ep};
            watch::alerts::close_alert($ctx, $ex, $_, $BELOW_QUOTA) for @open;
        }
    }
    # A-25: >= 5 watch_error or sweep_partial rows in a day.
    my %day;
    for my $r (rows_of($S, 'watch_error'), rows_of($S, 'sweep_partial')) {
        next unless defined $r->{ts} && $r->{ts} =~ /\A(\d{4}-\d\d-\d\d)/;
        $day{$1}++;
    }
    for my $d (sort keys %day) {
        next unless $day{$d} >= 5;
        $R->(rule => 'A-25', severity => 'warn', id_parts => [$d], evidence => { rows => $day{$d}, date => $d });
    }
    tick($ctx);
    # A-11: an item listed running for >= stall_min whose output has not moved. 0.1.3 alert
    # noise: only an item with a known output path is checked; without one the watcher cannot see
    # progress, and "quiet" was every such item (107 of 107 on 0.1.2). A shell whose path the result
    # text did not give has the file Claude Code writes for every background shell (task_output);
    # 0.1.4: a subagent has the link to its transcript there, a workflow its run journal (the run
    # its launch result named), which moves with its agents' transcripts beside it (progress_mtime);
    # teammates and monitors stay unchecked. The path is resolved when the
    # item is first seen and kept in the session state (`task_out`), which the re-check of older
    # rows (lib/watch/supersede.pm) reads too.
    my @slots = @{ $S->{bg} };
    my $tout = ref $sess->{task_out} eq 'HASH' ? $sess->{task_out} : ($sess->{task_out} = {});
    if (@slots) {
        for my $t (@{ $slots[-1]{tasks} }) {
            next unless defined $t->{id} && !ref $t->{id} && !defined $tout->{ $t->{id} };
            my $p = task_output($ctx, $t, $sess->{task_runs});
            $tout->{ $t->{id} } = $p if defined $p;
        }
        my %listed = map { defined $_->{id} && !ref $_->{id} ? ($_->{id} => 1) : () } map { @{ $_->{tasks} } } @slots;
        my @gone = grep { !$listed{$_} } sort keys %$tout;
        delete @{$tout}{ @gone[0 .. $#gone - $TASK_OUT_MAX] } if @gone > $TASK_OUT_MAX;
        my %first;
        for my $s (@slots) {
            for my $t (@{ $s->{tasks} }) {
                next unless defined $t->{id};
                $first{ $t->{id} } //= $s->{ts} // $s->{mtime};
            }
        }
        my $stall_s = 60 * $ctx->{settings}{stall_min};
        for my $t (@{ $slots[-1]{tasks} }) {
            next unless defined $t->{id} && ($t->{status} // 'running') =~ /\A(?:running|pending)\z/;
            next unless defined $first{ $t->{id} } && $now - $first{ $t->{id} } >= $stall_s;
            my $out = $t->{output_path} // $t->{outputFilePath};
            my $derived;
            unless (defined $out && !ref $out && length $out) {
                $out = $tout->{ $t->{id} } // next;
                $derived = 1;
            }
            # a derived output that is gone (the item's files were moved or removed since it was
            # first seen) cannot be checked: skipped, as an item with no such output
            my $mt = progress_mtime($out);
            next if $derived && !defined $mt;
            my $quiet = defined $mt ? ($now - $mt >= 900 ? 1 : 0) : 1;
            next unless $quiet;
            $R->(rule => 'A-11', severity => 'warn', id_parts => [$t->{id}],
                 evidence => { output_known => \1, minutes => int(($now - $first{ $t->{id} }) / 60),
                               ($derived ? (source => 'derived') : ()) });
        }
    }
}

# task_output(ctx, task) -> the output file Claude Code writes for a background shell with no
# recorded path, when it exists: <tmp>/claude-<uid>/<project>/<sid>/tasks/<id>.output, where
# <tmp> is CLAUDE_CODE_TMPDIR, else /tmp (Claude Code 2.1.316 does not read TMPDIR here; on
# macOS the recorded paths read /private/tmp, the same folder), and <project> is the session's
# project folder name, the one its transcript sits in under ~/.claude/projects. Without a
# transcript path (another session, lib/watch/supersede.pm) the folder is found by session id.
# A shell's file is a regular file. 0.1.4: a subagent's is a link to its transcript, and the
# transcript it points to is returned; a workflow's progress is its run journal,
# <project>/<sid>/subagents/workflows/<run>/journal.jsonl beside the session's transcript (the
# run from the slot, else from `runs`, {task id => run} as the sweep read the launch results).
# The journal stands for the run folder: its progress is progress_mtime's. Teammates and
# monitors: undef, as anything not found.
$TASK_OUT_MAX = 200;
sub task_output {
    my ($ctx, $t, $runs) = @_;
    my $id = $t->{id};
    return undef unless defined $id && !ref $id && $id =~ /\A[0-9A-Za-z_-]{1,64}\z/;
    my $type = $t->{type} // '';
    if ($type eq 'shell') {
        for my $d (task_dirs($ctx)) {
            my $p = "$d/$id.output";
            return $p if -f $p && !-l $p;
        }
    } elsif ($type eq 'subagent' || $type eq 'agent') {
        for my $d (task_dirs($ctx)) {
            my $p = "$d/$id.output";
            next unless -l $p;
            my $to = readlink $p;
            next unless defined $to && length $to;
            $to = "$d/$to" unless $to =~ m{\A/};
            return $to if -f $to;
        }
    } elsif ($type eq 'workflow') {
        my $run = $t->{run_id} // $t->{run} // (ref $runs eq 'HASH' ? $runs->{$id} : undef);
        return undef unless defined $run && !ref $run && $run =~ /\A[0-9A-Za-z_-]{1,64}\z/;
        for my $pd (project_dirs($ctx)) {
            my $j = "$pd/$ctx->{sid}/subagents/workflows/$run/journal.jsonl";
            return $j if -f $j && !-l $j;
        }
    }
    return undef;
}

# progress_mtime(output path) -> when the item's output last moved (epoch), undef when the path is
# gone. A workflow's run journal gets a row only when one of its agents starts or ends (real runs:
# unchanged for 77 to 307 minutes while agents worked), so for a run journal the newest of it and
# the run folder's agent transcripts (agent-<id>.jsonl, beside it) counts.
sub progress_mtime {
    my ($p) = @_;
    my @st = stat $p;
    return undef unless @st;
    my $mt = $st[9];
    if ($p =~ m{\A(.+/subagents/workflows/[0-9A-Za-z_-]{1,64})/journal\.jsonl\z}) {
        my $d = $1;
        for my $f (watch::io::list_dir($d)) {
            next unless $f =~ /\Aagent-[0-9A-Za-z_-]{1,64}\.jsonl\z/;
            my $m = (stat "$d/$f")[9];
            $mt = $m if defined $m && $m > $mt;
        }
    }
    return $mt;
}

# project_dirs(ctx) -> the folder of the session's transcript; without a transcript path (another
# session) every <config dir>/projects/* folder that holds a folder of the session id.
sub project_dirs {
    my ($ctx) = @_;
    my $sid = $ctx->{sid} // '';
    return () unless $sid =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/;
    my $tp = ref $ctx->{payload} eq 'HASH' ? $ctx->{payload}{transcript_path} : undef;
    return ($1) if defined $tp && !ref $tp && $tp =~ m{\A(.+)/\Q$sid\E\.jsonl\z};
    my $cd = (defined $ENV{CLAUDE_CONFIG_DIR} && length $ENV{CLAUDE_CONFIG_DIR}) ? $ENV{CLAUDE_CONFIG_DIR} : ($ENV{HOME} // '') . '/.claude';
    return grep { -d "$_/$sid" } map { "$cd/projects/$_" } watch::io::list_dir("$cd/projects");
}

sub task_dirs {
    my ($ctx) = @_;
    return @{ $ctx->{_task_dirs} } if ref $ctx->{_task_dirs} eq 'ARRAY';
    my $sid = $ctx->{sid} // '';
    my @d;
    if ($sid =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/) {
        # ctx cc_tmpdir: the cases' own folder (core passes none; the hook has Claude Code's env)
        my $base = $ctx->{cc_tmpdir} // $ENV{CLAUDE_CODE_TMPDIR};
        $base = '/tmp' unless defined $base && length $base;
        $base =~ s{/+\z}{};
        my $root = "$base/claude-$<";
        my $tp = ref $ctx->{payload} eq 'HASH' ? $ctx->{payload}{transcript_path} : undef;
        if (defined $tp && !ref $tp && $tp =~ m{([^/]+)/\Q$sid\E\.jsonl\z} && -d "$root/$1/$sid/tasks") {
            push @d, "$root/$1/$sid/tasks";
        } else {
            for my $e (watch::io::list_dir($root)) { push @d, "$root/$e/$sid/tasks" if -d "$root/$e/$sid/tasks" }
        }
    }
    $ctx->{_task_dirs} = \@d;
    return @d;
}

# 0.1.3 hook speed: the watch folder's size (A-24) is walked at most once per WATCH_MB_EVERY_S per
# session, the result kept in the session state ({ts, mb}): the walk grows with the store (every
# session's folder; up to 20,000 entries) and ran at every Stop. The walk may use WATCH_MB_SHARE of
# the time left before the run's hard stop; past that it gives up (no size, nothing kept) and the
# run goes on with the rest of the rules and commits, so a large store under load cannot drop
# every Stop's run at the hard stop (a walk that ran to the hard stop itself left the next tick()
# to drop the run); the next Stop walks again.
our $WATCH_MB_EVERY_S = 3600;
$WATCH_MB_CAP = 20000;
our $WATCH_MB_SHARE = 0.5;
$BELOW_QUOTA = 'resolved: below quota';
sub _utc_date { my @g = gmtime(int($_[0] // time)); return sprintf('%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3]) }

# _watch_mb(ctx, sess) -> {mb, over} (over: the walk stopped at WATCH_MB_CAP entries and mb is what
# it counted), the kept result while under an hour old; undef when the walk gave up.
sub _watch_mb {
    my ($ctx, $sess) = @_;
    my $now = $ctx->{now} // time;
    my $c = ref $sess eq 'HASH' && ref $sess->{watch_mb} eq 'HASH' ? $sess->{watch_mb} : undef;
    if ($c && defined $c->{ts} && defined $c->{mb} && $c->{ts} <= $now && $now - $c->{ts} < $WATCH_MB_EVERY_S) {
        return { mb => $c->{mb}, over => ($c->{over} ? 1 : 0) };
    }
    my $dl = $ctx->{_deadline};
    if (defined $dl) { my $m = watch::io::mono(); $dl = $m + ($dl - $m) * $WATCH_MB_SHARE }
    my $w = _dir_mb($ctx->{watch}, $WATCH_MB_CAP, $dl);
    return undef unless ref $w eq 'HASH';
    $sess->{watch_mb} = { ts => $now, mb => $w->{mb}, over => $w->{over} } if ref $sess eq 'HASH';
    return $w;
}

# _dir_mb(dir, cap, deadline) -> {mb => MB under dir, over => 0}; past cap entries {mb => the MB
# counted so far, over => 1}; 'late' at the deadline.
sub _dir_mb {
    my ($dir, $cap, $deadline) = @_;
    my ($bytes, $n) = (0, 0);
    my @q = ($dir);
    while (@q) {
        return 'late' if defined $deadline && watch::io::mono() >= $deadline;
        my $d = shift @q;
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            return { mb => $bytes / (1 << 20), over => 1 } if ++$n > $cap;
            return 'late' if defined $deadline && $n % 256 == 0 && watch::io::mono() >= $deadline;
            my $p = "$d/$e";
            my @st = lstat $p or next;
            if (-l _) { next }
            elsif (-d _) { push @q, $p }
            else { $bytes += $st[7] }
        }
        closedir $dh;
    }
    return { mb => $bytes / (1 << 20), over => 0 };
}

1;

package rollup;
# lib/rollup.pm: one rollup row per compaction in <watch>/<sid>/compactions.jsonl,
# keyed (session_id, actor, compaction_seq, nonce).
use strict;
use warnings;
use utf8;

our @FIELDS = qw(session_id actor compaction_seq nonce id6 join trigger midturn idle idle_source idle_gap_s channel seat_state
                 verdict verdict_source marker_line sentinel_from_end sentinel_place fabricated_check_tokens
                 instructions_bytes summary_chars shape_class pre_tokens post_tokens duration_ms precomputed
                 copy copy_path resume checkpoint_ms evidence nudged continued halt
                 proof proof_lag_ms settle_waited_ms acuity acuity_floor);
# proof P1 | P3 | none, proof_lag_ms, settle_waited_ms: window logging; acuity (the summary's
# Acuity word or -) and acuity_floor (from the dispatch's
# checkpoint facts, else -). idle, idle_source, idle_gap_s: idle_facts below.
# Enum values and numbers only.

sub write {
    my (%f) = @_;
    my @pairs = map { ($_ => $f{$_}) } @FIELDS;
    # ts: the compaction's own time when the row is written later (reconcile)
    return rc::emit('compaction', \@pairs, stream => 'compactions', actor => $f{actor}, ts => $f{ts});
}

# resume_state(sid_dir, nonce, scope, channel) -> the rollup `resume` value.
# The claim file <watch>/<sid>/resume-claimed/<nonce> decides first,
# whatever the actor: present -> `delivered:<channel>` (on the classic path SessionStart
# claims before PostCompact), or the claim's own `dropped:session-end`. No claim: a subagent
# on the classic path -> `undelivered` (its block would have come through SessionStart); a
# subagent on the mod path -> `none-subagent` (no block is built); main -> `pending` (the
# mod's logOutcome row settles it); scope unknown -> undef.
sub resume_state {
    my ($sid_dir, $nonce, $scope, $channel) = @_;
    my $claim = (defined $sid_dir && defined $nonce) ? util::read_file("$sid_dir/resume-claimed/$nonce") : undef;
    if (defined $claim && $claim =~ /^(\S+)/) {
        my $c = $1;
        return $c eq 'dropped:session-end' ? $c : "delivered:$c";
    }
    $scope //= 'unknown';
    return (($channel // '') eq 'classic' ? 'undelivered' : 'none-subagent') if $scope eq 'sub';
    return 'pending' if $scope eq 'main';
    return undef;
}

# rows(sid_dir) -> the compaction rows, each joined by nonce with the first compaction_boundary
# row for it: a null rollup size takes the boundary value; a non-null one is
# never replaced, and a disagreement sets join_conflict 1 on the row (0 when joined and equal).
our @JOIN = qw(pre_tokens post_tokens duration_ms precomputed);
our @JOIN_IDLE = qw(idle idle_source idle_gap_s);
sub rows {
    my ($sid_dir) = @_;
    my (@out, %b);
    open(my $fh, '<:raw', "$sid_dir/compactions.jsonl") or return \@out;
    while (my $l = <$fh>) {
        my $j = eval { jsonc::decode($l) } or next;
        next unless ref $j eq 'HASH';
        if (($j->{ev} // 'compaction') eq 'compaction_boundary') { $b{ $j->{nonce} } //= $j if defined $j->{nonce}; next }
        push @out, $j;
    }
    close $fh;
    for my $r (@out) {
        my $bd = defined $r->{nonce} ? $b{ $r->{nonce} } : undef;
        next unless $bd;
        my $conflict = 0;
        for my $k (@JOIN) {
            next unless defined $bd->{$k};
            if (!defined $r->{$k}) { $r->{$k} = $bd->{$k}; next }
            my ($x, $y) = map { jsonc::is_bool($_) ? ($_ ? 1 : 0) : "$_" } ($r->{$k}, $bd->{$k});
            $conflict = 1 if $x ne $y;
        }
        $r->{join_conflict} = $conflict;
        # the idle decision reconcile makes once the boundary row exists; the
        # PostCompact row says `unknown` (null source) until then
        for my $k (@JOIN_IDLE) {
            next unless exists $bd->{$k};
            $r->{$k} = $bd->{$k} if !defined $r->{$k} || (!ref $r->{$k} && $r->{$k} eq 'unknown');
        }
    }
    return \@out;
}

# idle_facts(drec, native) -> (idle, idle_source, idle_gap_s, mismatch) for a main compaction
# whose boundary row was read. mod = the mod record's `idle`
# (a classic or missing record: unknown); native = 'notice' | 'return' | undef (the first native
# idle row after the boundary). idle = mod OR native; idle_source both | mod | notice | return |
# none; mismatch 1 when the mod said true or false and the native row disagrees. An idle
# `mod-self` record is the plugin's own idle compaction (also while agents run):
# Claude Code writes no idle notice for it, so no native row is no mismatch.
sub idle_facts {
    my ($drec, $native) = @_;
    my $mod = ($drec && dispatch::is_mod($drec) && exists $drec->{idle} && defined $drec->{idle}) ? ($drec->{idle} ? 1 : 0) : undef;
    my $nat = defined $native ? 1 : 0;
    my $src = ($mod && $nat) ? 'both' : $mod ? 'mod' : $nat ? $native : 'none';
    my $gap = ($drec && defined $drec->{idle_gap_s} && !ref $drec->{idle_gap_s} && $drec->{idle_gap_s} =~ /\A\d+\z/) ? 0 + $drec->{idle_gap_s} : undef;
    my $own = ($mod && !$nat && ($drec->{channel} // '') eq 'mod-self') ? 1 : 0;
    my $mism = (defined $mod && $mod != $nat && !$own) ? 1 : 0;
    return (jsonc::bool($mod || $nat), $src, $gap, $mism);
}

# acuity_floor(sid_dir, nonce) -> the floor from the dispatch's checkpoint facts:
# the checkpoint's own acuity_floor when present; else unstable when git reports an operation
# in progress, watch when the inventory lists a running or pending job, else stable; - when the
# dispatch ran no checkpoint.
sub acuity_floor {
    my ($sid_dir, $nonce) = @_;
    return '-' unless defined $sid_dir && defined $nonce;
    my $raw = util::read_file("$sid_dir/checkpoint/$nonce.json") // return '-';
    my $c = eval { jsonc::decode($raw) };
    return '-' unless ref $c eq 'HASH';
    return $c->{acuity_floor} if defined $c->{acuity_floor} && !ref $c->{acuity_floor} && $c->{acuity_floor} =~ /\A(?:stable|watch|unstable)\z/;
    return 'unstable' if ref $c->{git} eq 'HASH' && ref $c->{git}{in_progress} eq 'ARRAY' && @{ $c->{git}{in_progress} };
    return 'watch' if grep { ref $_ eq 'HASH' && ($_->{kind} // '') ne 'cron' && ($_->{status} // '') =~ /\A(?:running|pending)\z/ } @{ ref $c->{inventory} eq 'ARRAY' ? $c->{inventory} : [] };
    return 'stable';
}

# Rows of a log stream (classic or mod), decoded.
# stream_rows(path, evs => [ev, ...], tail => bytes): `evs` decodes only rows of those
# events (a line is skipped before the JSON decode unless its "ev" value is listed, so a
# long session's sweep and session rows cost a regex test, not a decode); `tail` reads
# only the last bytes of the file (the partial first line dropped).
sub stream_rows {
    my ($path, %o) = @_;
    my @out;
    return \@out unless defined $path;
    my $want;
    if ($o{evs}) { my $alt = join('|', map { quotemeta } @{ $o{evs} }); $want = qr/"ev"\s*:\s*"(?:$alt)"/ }
    my @lines;
    if ($o{tail}) {
        my $data = util::read_tail($path, $o{tail}) // return \@out;
        @lines = split /\n/, $data;
    } else {
        open(my $fh, '<:raw', $path) or return \@out;
        while (my $l = <$fh>) {
            next if $want && $l !~ $want;
            my $j = eval { jsonc::decode($l) } or next;
            push @out, $j if ref $j eq 'HASH';
        }
        close $fh;
        return \@out;
    }
    for my $l (@lines) {
        next if $want && $l !~ $want;
        my $j = eval { jsonc::decode($l) } or next;
        push @out, $j if ref $j eq 'HASH';
    }
    return \@out;
}

1;

package rollup;
# lib/rollup.pm: one rollup row per compaction in <watch>/<sid>/compactions.jsonl
# (MOD-SPEC §2.5 table), keyed (session_id, actor, compaction_seq, nonce).
# Owner: WP-core.
use strict;
use warnings;

our @FIELDS = qw(session_id actor compaction_seq nonce id6 join trigger midturn idle channel seat_state
                 verdict verdict_source marker_line sentinel_from_end fabricated_check_tokens
                 instructions_bytes summary_chars shape_class pre_tokens post_tokens duration_ms precomputed
                 copy copy_path resume checkpoint_ms evidence nudged continued halt);

sub write {
    my (%f) = @_;
    my @pairs = map { ($_ => $f{$_}) } @FIELDS;
    # ts: the compaction's own time when the row is written later (reconcile, F2-1)
    return rc::emit('compaction', \@pairs, stream => 'compactions', actor => $f{actor}, ts => $f{ts});
}

sub rows {
    my ($sid_dir) = @_;
    my @out;
    open(my $fh, '<:raw', "$sid_dir/compactions.jsonl") or return \@out;
    while (my $l = <$fh>) {
        my $j = eval { jsonc::decode($l) } or next;
        push @out, $j if ref $j eq 'HASH';
    }
    close $fh;
    return \@out;
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

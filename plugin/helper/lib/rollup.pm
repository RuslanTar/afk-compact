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
    return rc::emit('compaction', \@pairs, stream => 'compactions', actor => $f{actor});
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
sub stream_rows {
    my ($path) = @_;
    my @out;
    open(my $fh, '<:raw', $path) or return \@out;
    while (my $l = <$fh>) {
        my $j = eval { jsonc::decode($l) } or next;
        push @out, $j if ref $j eq 'HASH';
    }
    close $fh;
    return \@out;
}

1;

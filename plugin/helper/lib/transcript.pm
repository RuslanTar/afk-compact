package transcript;
# lib/transcript.pm: read-only transcript facts, parsed by key (TF Q3 §1a). Owner: WP-core.
# Only ids, counts, flags and timestamps leave this module; text is read in memory.
use strict;
use warnings;
use utf8;

# boundary(line) -> {uuid, ts, epoch, trigger, pre, post, duration_ms, precomputed} or undef
sub boundary {
    my ($line) = @_;
    return undef unless index($line, 'compact_boundary') >= 0;
    my $j = eval { jsonc::decode($line) };
    return undef unless ref $j eq 'HASH' && ($j->{subtype} // '') eq 'compact_boundary';
    my $m = ref $j->{compactMetadata} eq 'HASH' ? $j->{compactMetadata} : {};
    return { uuid => $j->{uuid}, ts => $j->{timestamp}, epoch => util::parse_iso($j->{timestamp} // '') // 0,
             trigger => $m->{trigger}, pre => $m->{preTokens}, post => $m->{postTokens},
             duration_ms => $m->{durationMs}, precomputed => ($m->{precomputed} ? 1 : 0) };
}

# boundaries(path [, tail => bytes]) -> [{uuid, ts, epoch, trigger, pre, post, duration_ms, precomputed}]
# (tail: only the last bytes of the file, for a hook that wants the newest rows)
sub boundaries {
    my ($path, %o) = @_;
    my @out;
    return \@out unless defined $path && -f $path;
    if ($o{tail}) {
        my $data = util::read_tail($path, $o{tail}) // return \@out;
        for my $line (split /\n/, $data) { my $b = boundary($line); push @out, $b if $b }
        return \@out;
    }
    open(my $fh, '<:raw', $path) or return \@out;
    while (my $line = <$fh>) { my $b = boundary($line); push @out, $b if $b }
    close $fh;
    return \@out;
}

sub count { return scalar @{ boundaries($_[0]) } }

# last_prompt_epoch(path) -> epoch of the last user-typed row (not a tool result,
# not a compact summary, not meta) in the last 2 MB, or undef
sub last_prompt_epoch {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $tail = util::read_tail($path, 2 * 1024 * 1024) // return undef;
    my $best;
    for my $line (split /\n/, $tail) {
        next unless index($line, '"user"') >= 0;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'user';
        next if $j->{isCompactSummary} || $j->{isMeta} || $j->{isSidechain};
        my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
        next if ref $c eq 'ARRAY' && grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c;
        my $e = util::parse_iso($j->{timestamp} // '');
        $best = $e if defined $e && (!defined $best || $e > $best);
    }
    return $best;
}

# subagent_files(main transcript path, sid) -> [{path, agent_id}]
sub subagent_files {
    my ($path, $sid) = @_;
    return [] unless defined $path && $path ne '';
    my $dir = util::dirname($path);
    my $stem = util::basename($path);
    $stem =~ s/\.jsonl$//;
    my @out;
    for my $base (grep { defined } ($stem, $sid)) {
        my $d = "$dir/$base/subagents";
        next unless -d $d;
        for my $f (util::list_dir($d)) {
            next unless $f =~ /^agent-([A-Za-z0-9_-]+)\.jsonl$/;
            push @out, { path => "$d/$f", agent_id => $1 };
        }
        last if @out;
    }
    return \@out;
}

# Temp paths cited in the last 5 MB of a transcript (sweep scope, OD-9).
sub temp_paths {
    my ($path, $tmpdir) = @_;
    return [] unless defined $path && -f $path;
    my $tail = util::read_tail($path, 5 * 1024 * 1024) // return [];
    my @roots = ('/tmp/', '/private/tmp/', '/var/folders/');
    push @roots, "$tmpdir/" if defined $tmpdir && $tmpdir =~ m{^/} && $tmpdir ne '/';
    my %seen;
    my @out;
    while ($tail =~ m{((?:/private)?/(?:tmp|var/folders)/[^\s"'<>\\|;&\x60]+|[^\s"'<>\\|;&\x60]*/tasks/[A-Za-z0-9_.-]+\.output)}g) {
        my $p = $1;
        $p =~ s/[),.:]+$//;
        next if $seen{$p}++;
        push @out, $p;
    }
    if (defined $tmpdir && $tmpdir =~ m{^/.+}) {
        my $t = $tmpdir;
        $t =~ s{/+$}{};
        while ($tail =~ m{(\Q$t\E/[^\s"'<>\\|;&\x60]+)}g) {
            my $p = $1;
            $p =~ s/[),.:]+$//;
            next if $seen{$p}++;
            push @out, $p;
        }
    }
    return \@out;
}

1;

package measure;
# lib/measure.pm: facts measured by code (MOD-SPEC §2.6 `measure --compact`, §10
# measured block). Order: git; in-flight inventory (every listed id); evidence map
# (<= 8 rows from this compaction's checkpoint or sweep); GSD (own worktree, <= 8
# lines); the Queued: line when queue_cmd is set. <= 3,000 B, cut at a line
# boundary with `(+N lines)`. No `Approvals (verified)` section in v1 (D-2).
# Owner: WP-core.
use strict;
use warnings;

our $MAX = 3000;

sub git_lines {
    my ($g) = @_;
    return ('git: not measured (timeout)') if $g->{status} eq 'timeout';
    return ('git: unavailable') if $g->{status} eq 'unavailable';
    return ('git: not a repository') if $g->{status} eq 'not-git';
    my $l = sprintf('git: branch %s · HEAD %s · %d changed · ahead %d behind %d%s',
                    $g->{branch} // '(detached)', $g->{head} // '-', $g->{count}, $g->{ahead}, $g->{behind},
                    $g->{op} ? " · $g->{op} in progress" : '');
    my @out = ($l);
    push @out, map { "  $_" } @{ $g->{porcelain} || [] };
    push @out, sprintf('  (+%d more)', $g->{count} - 20) if $g->{count} > 20;
    return @out;
}

sub inflight_lines {
    my ($slot) = @_;
    return ('In flight: not listed (no sidecar yet)') unless $slot;
    my @t = @{ $slot->{tasks} || [] };
    my @c = @{ $slot->{crons} || [] };
    return ('In flight (sidecar ' . util::hhmm(util::parse_iso($slot->{ts} // '') // util::now()) . '): nothing listed') unless @t || @c;
    my @out = ('In flight (sidecar ' . util::hhmm(util::parse_iso($slot->{ts} // '') // util::now()) . '):');
    for my $x (@t) {
        my $line = "  $x->{id} · $x->{type} · $x->{status}";
        if (defined $x->{output_path}) { $line .= " · output $x->{output_path} (" . (-e $x->{output_path} ? 'exists' : 'missing') . ')' }
        push @out, $line;
    }
    push @out, "  $_ · cron · scheduled" for @c;
    return @out;
}

sub evidence_lines {
    my ($rows) = @_;
    my @r = grep { $_->{status} =~ /^(copied|redacted|dup|ref-only)$/ } @{ $rows || [] };
    return () unless @r;
    my @out = ('Evidence (automatic copies):');
    for my $x (@r[0 .. ($#r > 7 ? 7 : $#r)]) {
        push @out, sprintf('  %s → %s (%s)', $x->{origin}, util::abbrev($x->{copy} // '-'), $x->{status});
    }
    push @out, sprintf('  (+%d more)', @r - 8) if @r > 8;
    return @out;
}

sub gsd_lines {
    my ($g) = @_;
    return () unless $g && $g->{status} eq 'ok';
    return ('GSD (' . util::abbrev($g->{path}) . '):', map { "  $_" } @{ $g->{lines} });
}

sub cap {
    my ($lines, $max) = @_;
    $max //= $MAX;
    my @l = @$lines;
    my $text = join("\n", @l);
    my $len = do { my $c = $text; utf8::encode($c) if utf8::is_utf8($c); length $c };
    return $text if $len <= $max;
    my @keep;
    my $size = 0;
    for my $i (0 .. $#l) {
        my $c = $l[$i];
        utf8::encode($c) if utf8::is_utf8($c);
        my $tag = sprintf('(+%d lines)', @l - $i);
        last if $size + length($c) + 1 + length($tag) > $max;
        push @keep, $l[$i];
        $size += length($c) + 1;
    }
    push @keep, sprintf('(+%d lines)', @l - @keep);
    return join("\n", @keep);
}

# Latest evidence rows of this session's newest checkpoint for a nonce, or none.
sub _evidence_rows {
    my ($sid_dir, $nonce) = @_;
    my @files = $nonce ? ("$sid_dir/checkpoint/$nonce.json") : map { "$sid_dir/checkpoint/$_" }
                reverse sort { (stat "$sid_dir/checkpoint/$a")[9] <=> (stat "$sid_dir/checkpoint/$b")[9] }
                grep { /\.json$/ } util::list_dir("$sid_dir/checkpoint");
    for my $f (@files) {
        my $raw = util::read_file($f) // next;
        my $j = eval { jsonc::decode($raw) } or next;
        return $j->{evidence_rows} if ref $j eq 'HASH' && ref $j->{evidence_rows} eq 'ARRAY';
        return [map { { origin => $_->{origin}, copy => $_->{copy}, status => $_->{status} } } @{ $j->{evidence_map} || [] }]
            if ref $j eq 'HASH';
    }
    return [];
}

# compact(sid, cwd, nonce, %o{git => result, lane => result}) -> text (<= 3,000 B)
sub compact {
    my ($sid, $cwd, $nonce, %o) = @_;
    my $t0 = util::clock_ms();
    util::trace('measure');
    my $sid_dir = rc::sid_dir();
    my $g = $o{git} || git::measure($cwd, 2000);
    my @l = git_lines($g);
    push @l, inflight_lines(defined $sid_dir ? sidecar::newest($sid_dir) : undef);
    push @l, evidence_lines($o{evidence_rows} || (defined $sid_dir ? _evidence_rows($sid_dir, $nonce) : []));
    my $wt = $o{worktree} // (git::where($cwd)->{toplevel});
    push @l, gsd_lines(gsd::read($wt));
    my $lane = $o{lane};
    if (!$lane && defined rc::val('queue_cmd') && rc::val('queue_cmd') ne '') {
        $lane = queue::lane($sid, rc::val('queue_cmd'), 3000);
    }
    push @l, $lane->{queued_line} if $lane && $lane->{queued_line};
    my $text = cap(\@l, $o{max} // $MAX);
    my $bytes = do { my $c = $text; utf8::encode($c) if utf8::is_utf8($c); length $c };
    rc::emit('measure', [bytes => $bytes, ms => util::clock_ms() - $t0]) unless $o{quiet};
    return $text;
}

1;

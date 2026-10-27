package measure;
# lib/measure.pm: facts measured by code (MOD-SPEC §2.6 `measure --compact`, §10
# measured block). Order: the git header line; this session's GSD lines (lib/gsd.pm: from its
# own transcript, never from the worktree alone; none for a session that worked with neither GSD
# nor a driver skill; before the porcelain list, so the cap cuts porcelain lines first); the
# porcelain list (<= 20 lines); in-flight inventory (every listed id);
# evidence map (<= 8 rows from this compaction's checkpoint or sweep); the Queued: line when
# queue_cmd is set. <= 3,000 B, cut at a line boundary with `(+N lines)`. With `--copy`
# (AP-5) the approvals lines of the summary follow the git and GSD lines (cmd/measure.pl
# checks them); without it there is none. Times are stamps (`In flight (sidecar 2026-10-21 14:05 +0300)`, RV-24).
# Owner: WP-core.
use strict;
use warnings;
use utf8;

our $MAX = 3000;

sub git_lines {
    my ($g) = @_;
    return ('git: not measured (timeout)') if $g->{status} eq 'timeout';
    return ('git: unavailable') if $g->{status} eq 'unavailable';
    return ('git: not a repository') if $g->{status} eq 'not-git';
    # With no upstream (a new local branch, a detached HEAD) or one whose ref is gone, the commits
    # not pushed are unknown: the line says so instead of `ahead 0` (the away digest's Basis reads
    # it; review of the away-digest fix round 2).
    my $u = $g->{upstream} // 'set';
    my $l = sprintf('git: branch %s · HEAD %s · %d changed · %s%s',
                    $g->{branch} // '(detached)', $g->{head} // '-', $g->{count},
                    $u eq 'none' ? 'no upstream' : $u eq 'gone' ? 'upstream gone' : sprintf('ahead %d behind %d', $g->{ahead}, $g->{behind}),
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
    return ('In flight (sidecar ' . util::stamp(util::parse_iso($slot->{ts} // '') // util::now()) . '): nothing listed') unless @t || @c;
    my @out = ('In flight (sidecar ' . util::stamp(util::parse_iso($slot->{ts} // '') // util::now()) . '):');
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

# gsd_lines(gsd::session result) -> its lines (none for a session without GSD or a driver).
sub gsd_lines {
    my ($g) = @_;
    return () unless ref $g eq 'HASH' && ref $g->{lines} eq 'ARRAY';
    return @{ $g->{lines} };
}

# The GSD scan's budget inside a measure: at most gsd::$SCAN_MS, never past the caller's deadline.
sub gsd_session {
    my ($sid, $cwd, $wt, $transcript, $ms) = @_;
    return { status => 'timeout', lines => ['GSD: not measured (timeout)'] } if $ms < 100;
    my $sid_dir = rc::sid_dir();
    return eval { gsd::session(sid => $sid, transcript => $transcript, cwd => $cwd, worktree => $wt,
                               cache_dir => (defined $sid_dir && -d $sid_dir ? $sid_dir : undef), budget_ms => $ms) }
        // { status => 'unread', lines => [] };
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

our %SCAN_STATUS = (full => 'copied', redacted => 'redacted', excerpt => 'redacted', 'ref-only' => 'ref-only', withheld => 'withheld');

# Rows of the sweep that claimed swept/<nonce6> for this nonce, from its MANIFEST.tsv.
sub _sweep_rows {
    my ($sid_dir, $nonce) = @_;
    my $claim = util::read_file("$sid_dir/swept/" . substr($nonce, 0, 6)) // return undef;
    my ($n, $dest) = $claim =~ /^([0-9a-f]{8})?\t([^\n]+)/ or return undef;
    return undef unless defined $n && $n eq $nonce && -d $dest;
    my $m = util::text(util::read_file("$dest/MANIFEST.tsv")) // return [];
    my @rows;
    for my $l (split /\n/, $m) {
        my ($copy, $origin, undef, undef, undef, undef, undef, $scan) = split /\t/, $l;
        next unless defined $scan && $SCAN_STATUS{$scan} && $copy ne 'copy_path';
        push @rows, { origin => $origin, copy => ($copy eq '-' ? undef : $copy), status => $SCAN_STATUS{$scan} };
    }
    return \@rows;
}

# Evidence rows of this compaction: its checkpoint, else its sweep (the after-step's or
# PostCompact's); with no nonce, this session's newest checkpoint.
sub _evidence_rows {
    my ($sid_dir, $nonce) = @_;
    if ($nonce && !-f "$sid_dir/checkpoint/$nonce.json") { return _sweep_rows($sid_dir, $nonce) // [] }
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

# compact(sid, cwd, nonce, %o{git => result, lane => result, budget_ms => N, transcript => path,
#   gsd => gsd::session result}) -> text (<= 3,000 B)
# One budget for every step that waits (git 2 s, queue 3 s at most): a step that would
# start with too little time left is skipped (git reads `not measured (timeout)`, the
# Queued: line is left out), so a hook caller stays inside its own timeout.
our $BUDGET_MS = 7000;

sub compact {
    my ($sid, $cwd, $nonce, %o) = @_;
    my $t0 = util::clock_ms();
    my $deadline = $t0 + ($o{budget_ms} // $BUDGET_MS);
    my $left = sub { my ($cap) = @_; my $l = $deadline - util::clock_ms(); return $l > $cap ? $cap : $l };
    util::trace('measure');
    my $sid_dir = rc::sid_dir();
    my $g = $o{git} || ($left->(2000) >= 200 ? git::measure($cwd, $left->(2000)) : { status => 'timeout' });
    my @gl = git_lines($g);
    my $wt = $o{worktree} // $g->{toplevel};
    $wt //= git::where($cwd, $left->(2000))->{toplevel} if $g->{status} eq 'ok' && $left->(2000) >= 200;
    # The GSD lines go right after the git header line, before the porcelain list, so the cap
    # cuts porcelain lines first and never the re-enter command.
    my @l = (shift @gl, gsd_lines($o{gsd} // gsd_session($sid, $cwd, $wt, $o{transcript}, $left->($gsd::SCAN_MS))), @gl);
    push @l, @{ $o{approvals} } if ref $o{approvals} eq 'ARRAY';
    push @l, inflight_lines(defined $sid_dir ? sidecar::newest($sid_dir) : undef);
    push @l, evidence_lines($o{evidence_rows} || (defined $sid_dir ? _evidence_rows($sid_dir, $nonce) : []));
    my $lane = $o{lane};
    if (!$lane && defined rc::val('queue_cmd') && rc::val('queue_cmd') ne '' && $left->(3000) >= 200) {
        $lane = queue::lane($sid, rc::val('queue_cmd'), $left->(3000));
    }
    push @l, $lane->{queued_line} if $lane && $lane->{queued_line};
    my $text = cap(\@l, $o{max} // $MAX);
    my $bytes = do { my $c = $text; utf8::encode($c) if utf8::is_utf8($c); length $c };
    rc::emit('measure', [bytes => $bytes, ms => util::clock_ms() - $t0]) unless $o{quiet};
    return $text;
}

# brief(sid, cwd, %o{git => result}) -> one line <= $BRIEF_MAX bytes for ID-3's `[idle-return]`
# context line: `git: <branch> @ <head>, dirty <n> · in flight: <n> running, <n> ended`. One git
# call (2 s at most) and the newest sidecar slot; nothing else.
our $BRIEF_MAX = 600;

sub brief {
    my ($sid, $cwd, %o) = @_;
    my $t0 = util::clock_ms();
    my $g = $o{git} || git::measure($cwd, 2000);
    my $st = $g->{status} // 'unavailable';
    my $gl = $st eq 'ok' ? sprintf('git: %s @ %s, dirty %d', $g->{branch} // '(detached)', $g->{head} // '-', $g->{count} // 0)
           : $st eq 'timeout' ? 'git: not measured (timeout)'
           : $st eq 'not-git' ? 'git: not a repository' : 'git: unavailable';
    my $sid_dir = rc::sid_dir();
    my $slot = defined $sid_dir ? sidecar::newest($sid_dir) : undef;
    my $fl = 'in flight: not listed';
    if ($slot) {
        my @t = @{ $slot->{tasks} || [] };
        my $run = grep { ($_->{status} // '') =~ /\A(?:running|pending)\z/i } @t;
        $fl = sprintf('in flight: %d running, %d ended', $run, @t - $run);
    }
    my $line = "$gl · $fl";
    my $bytes = do { my $c = $line; utf8::encode($c) if utf8::is_utf8($c); length $c };
    if ($bytes > $BRIEF_MAX) {
        $line = 'git: branch name too long · ' . $fl;
        $bytes = do { my $c = $line; utf8::encode($c) if utf8::is_utf8($c); length $c };
    }
    rc::emit('measure', [bytes => $bytes, ms => util::clock_ms() - $t0, brief => jsonc::true()]) unless $o{quiet};
    return $line;
}

1;

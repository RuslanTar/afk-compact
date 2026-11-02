package watch::status;
# lib/watch/status.pm: the watcher's lines in `status` (MOD-SPEC §11, WATCH
# §7.2): open alerts for this session and the last 7 days' counts by rule.
# Owner: WP-watch. Fixed texts, ids and counts only; never content.
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::alerts;

my %RANK = (critical => 0, warn => 1, info => 2);
my $SHOW = 10;

sub lines {
    my ($ctx) = @_;
    watch::ctx::init($ctx);
    my @out;
    unless (watch::ctx::watcher_on($ctx)) {
        push @out, 'Watcher: off';
        return \@out;
    }
    my $mode = $watch::alerts::DELIVERY eq 'status-only'
             ? 'alerts are shown here only (Stop delivery waits for probe P-W2)'
             : 'alerts are shown at the next Stop and here';
    push @out, "Watcher: shadow; $mode";
    push @out, q(Watcher: the watcher setting is not "shadow" or "off"; it counts as shadow) if $ctx->{settings}{watcher_unknown};
    if (my $why = watch::ctx::refused($ctx)) {
        push @out, "Watcher: writes nothing ($why)";
    }
    if (defined $ctx->{sid} && $ctx->{sid} =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/) {
        my $ex = watch::alerts::load_existing($ctx);
        my @rows = sort { ($RANK{ $a->{severity} // 'info' } // 3) <=> ($RANK{ $b->{severity} // 'info' } // 3)
                          || ($a->{ts} // '') cmp ($b->{ts} // '') } @{ $ex->{open} };
        my %sev;
        $sev{ $_->{severity} // 'info' }++ for @rows;
        push @out, sprintf('Alerts this session: %d (critical %d, warn %d, info %d)',
                           scalar @rows, $sev{critical} // 0, $sev{warn} // 0, $sev{info} // 0);
        for my $r (@rows[0 .. ($#rows < $SHOW - 1 ? $#rows : $SHOW - 1)]) {
            push @out, sprintf('  %s %s %s: %s', $r->{severity} // 'info', $r->{rule} // '?', $r->{alert_id},
                               watch::alerts::text_for($ctx, $r->{rule} // ''));
        }
        push @out, sprintf('  (+%d more)', @rows - $SHOW) if @rows > $SHOW;
        push @out, join_conflict_lines($ctx);
    }
    my ($counts, $sessions) = week_counts($ctx);
    push @out, @$counts
        ? 'Alerts, last 7 days: ' . join(', ', map { "$_->[0] $_->[1]" } @$counts) . " ($sessions sessions)"
        : 'Alerts, last 7 days: none';
    push @out, superseded_lines($ctx);
    push @out, stash_lines($ctx);
    my $last = last_row_ts($ctx);
    push @out, 'Last watcher row: ' . ($last // 'none');
    return \@out;
}

# 0.1.3 alert noise: the one-line verdict that opens `status` (cmd/status.pl), or undef while
# the watcher is off. With a session id it reads this session: its main compactions in the
# rollup (precomputed ones left out) with a saved copy, and its open alerts, the warn and
# critical ones (an info alert is a note and asks for nothing). Without one it reads the store
# over the last 7 days, as the 7-day counts do. `ok` only when every compaction has its copy
# and no alert is open; else `attention`, with the open alerts by rule.
#   ok: 5/5 compactions saved this session, no open alerts
#   attention: 2 open alerts (A-01, A-05); 4/5 compactions saved this session
my $SAVED = qr/\A(?:saved|unattributed|late|exists)\z/;
sub verdict {
    my ($ctx) = @_;
    watch::ctx::init($ctx);
    return undef unless watch::ctx::watcher_on($ctx);
    my (@alerts, @rolls, $scope);
    if (defined $ctx->{sid} && $ctx->{sid} =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/) {
        $scope = 'this session';
        @alerts = @{ watch::alerts::load_existing($ctx)->{open} };
        @rolls = _rollup_rows(watch::ctx::sid_dir($ctx) . '/compactions.jsonl');
    } else {
        $scope = 'in the last 7 days';
        my $cut = $ctx->{now} - 7 * 86400;
        my $w = $ctx->{watch};
        my $recent = sub { my $t = watch::io::parse_iso($_[0]{ts}); return defined $t && $t >= $cut };
        for my $f (watch::io::list_dir($w)) {
            if ($f =~ /\.alerts\.jsonl\z/) {
                my $mt = (stat "$w/$f")[9];
                next unless defined $mt && $mt >= $cut;
                my ($al, $closed) = watch::alerts::read_log("$w/$f");
                push @alerts, grep { !exists $closed->{ $_->{alert_id} } && $recent->($_) } @$al;
            } elsif ($f =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/ && -d "$w/$f") {
                # by the rollup stream's own time: the folder's changes only when an entry is added
                my $mt = (stat "$w/$f/compactions.jsonl")[9];
                next unless defined $mt && $mt >= $cut;
                push @rolls, grep { $recent->($_) } _rollup_rows("$w/$f/compactions.jsonl");
            }
        }
    }
    my %open;
    $open{ $_->{rule} // '?' }++ for grep { ($_->{severity} // '') =~ /\A(?:critical|warn)\z/ } @alerts;
    my $n = 0;
    $n += $_ for values %open;
    my $saved = grep { defined $_->{copy} && !ref $_->{copy} && $_->{copy} =~ $SAVED } @rolls;
    my $copies = @rolls ? sprintf('%d/%d compactions saved %s', $saved, scalar @rolls, $scope) : "no compactions $scope";
    return "ok: $copies, no open alerts" if !$n && $saved == @rolls;
    return "attention: $copies, no open alerts" unless $n;
    return sprintf('attention: %d open alert%s (%s); %s', $n, ($n == 1 ? '' : 's'), join(', ', sort keys %open), $copies);
}

# The main compaction rows of one rollup stream (precomputed ones and core's
# `compaction_boundary` rows left out), one per compaction: the last row of a nonce counts (a
# late copy from reconcile after the first row); rows without a nonce count each.
sub _rollup_rows {
    my ($p) = @_;
    return () unless -f $p && !-l $p;
    my (%by, @order);
    my $i = 0;
    for my $r (@{ watch::io::read_jsonl($p) }) {
        next unless ($r->{ev} // 'compaction') eq 'compaction' && ($r->{actor} // '') eq 'main';
        my $pc = $r->{precomputed};
        $pc = $$pc if ref $pc eq 'SCALAR';
        next if $pc && !ref $pc;
        my $n = $r->{nonce};
        my $k = (defined $n && !ref $n && $n ne '' && $n ne 'none') ? "n:$n" : 'i:' . $i++;
        push @order, $k unless exists $by{$k};
        $by{$k} = $r;
    }
    return map { $by{$_} } @order;
}

# C-STORE D4/D10 (MOD-SPEC §5.8): the stashes the cross-session finish cannot reach
# because their session left no per-process record (<root>/.sessions/by-pid/*.{live,ended}-
# <sid8>.json). Counts and sid8s only; one line, shown only when the count is not zero.
# Read-only (F2-5: core writes these files). The stashes kept after a real mismatch
# (`pending/*.mismatch.md`) are core's `status` line (`kept mismatch stashes: N`, with their
# paths; needs/core-to-watch.md §8), so the watcher no longer repeats their count.
our $STASH_SIDS = 5;
sub stash_lines {
    my ($ctx) = @_;
    my $w = $ctx->{watch};
    my %rec;
    for my $f (watch::io::list_dir(($ctx->{root} // '') . '/.sessions/by-pid')) {
        $rec{$1} = 1 if $f =~ /\A[0-9]+-[0-9]+\.(?:live|ended)-([0-9A-Za-z-]{1,8})\.json\z/;
    }
    my $own = $ctx->{sid} // '';
    my @unreached;
    for my $sid (watch::io::list_dir($w)) {
        next unless $sid =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/ && -d "$w/$sid/pending";
        # a kept `*.mismatch.md` is not an open stash
        my $open = grep { /\.(?:post|mod)\.md\z/ && !/\.mismatch\.md\z/ } watch::io::list_dir("$w/$sid/pending");
        push @unreached, substr($sid, 0, 8) if $open && $sid ne $own && !$rec{ substr($sid, 0, 8) };
    }
    my @o;
    if (@unreached) {
        my @show = @unreached[0 .. ($#unreached < $STASH_SIDS - 1 ? $#unreached : $STASH_SIDS - 1)];
        push @o, sprintf('Stashes no other session can finish (their session left no process record): %d session%s (%s%s)',
                         scalar @unreached, (@unreached == 1 ? '' : 's'), join(', ', @show),
                         (@unreached > @show ? sprintf(', +%d more', @unreached - @show) : ''));
    }
    return @o;
}

# PKG-RUNTIME E.2 (WATCHER-SPEC §6.3 `compaction_boundary`): this session's rollup rows whose
# non-null size disagrees with core's boundary row for the same nonce (`join_conflict`; the
# rollup value is kept). One line, shown only when the count is not zero. Read-only.
sub join_conflict_lines {
    my ($ctx) = @_;
    require watch::rules;
    my $p = watch::ctx::sid_dir($ctx) . '/compactions.jsonl';
    return () unless -f $p && !-l $p;
    my (undef, undef, $n) = watch::rules::join_rollup(watch::io::read_jsonl($p));
    return $n ? (sprintf('Compaction size join conflicts this session: %d (the rollup value is kept)', $n)) : ();
}

sub week_counts {
    my ($ctx) = @_;
    my $cut = $ctx->{now} - 7 * 86400;
    my (%n, %s);
    for my $f (watch::io::list_dir($ctx->{watch})) {
        next unless $f =~ /\A(.+)\.alerts\.jsonl\z/;
        my $sid = $1;
        my $p = "$ctx->{watch}/$f";
        my $mt = (stat $p)[9];
        next unless defined $mt && $mt >= $cut;
        # 0.1.3: a closed alert (lib/watch/alerts.pm) is not counted
        my ($rows, $closed) = watch::alerts::read_log($p);
        for my $r (@$rows) {
            next if exists $closed->{ $r->{alert_id} };
            my $t = watch::io::parse_iso($r->{ts});
            next unless defined $t && $t >= $cut;
            $n{ $r->{rule} // '?' }++;
            $s{$sid} = 1;
        }
    }
    return ([ map { [$_, $n{$_}] } sort keys %n ], scalar keys %s);
}

# 0.1.3 (lib/watch/supersede.pm): one line with the number of alerts closed as superseded in
# the last 7 days (by the close row's time), store-wide; none when there are none.
sub superseded_lines {
    my ($ctx) = @_;
    my $cut = $ctx->{now} - 7 * 86400;
    my %ids;
    for my $f (watch::io::list_dir($ctx->{watch})) {
        next unless $f =~ /\.alerts\.jsonl\z/;
        my $p = "$ctx->{watch}/$f";
        my $mt = (stat $p)[9];
        next unless defined $mt && $mt >= $cut;
        for my $r (@{ watch::io::read_jsonl($p, undef, qr/"ev"\s*:\s*"alert_closed"/) }) {
            next unless ($r->{ev} // '') eq 'alert_closed' && defined $r->{alert_id} && !ref $r->{alert_id};
            next unless ($r->{reason} // '') =~ /\Asuperseded:/;
            my $t = watch::io::parse_iso($r->{ts});
            $ids{"$f/$r->{alert_id}"} = 1 if defined $t && $t >= $cut;
        }
    }
    my $n = keys %ids;
    return $n ? (sprintf('Alerts closed as superseded (the rule changed in 0.1.3; rows kept): %d', $n)) : ();
}

sub last_row_ts {
    my ($ctx) = @_;
    my ($best, $bt);
    for my $f (watch::io::list_dir($ctx->{watch})) {
        next unless $f =~ /\.classic\.jsonl\z/;
        my $mt = (stat "$ctx->{watch}/$f")[9];
        if (defined $mt && (!defined $bt || $mt > $bt)) { $best = $f; $bt = $mt }
    }
    return undef unless $best;
    my $p = "$ctx->{watch}/$best";
    open(my $fh, '<:raw', $p) or return undef;
    my $size = -s $fh;
    seek($fh, $size > 8192 ? $size - 8192 : 0, 0);
    my $last;
    while (my $l = <$fh>) { $last = $l if $l =~ /"ts"/ }
    close $fh;
    return undef unless defined $last && $last =~ /"ts":"([0-9T:.+\-]{10,40})"/;
    return $1;
}

1;

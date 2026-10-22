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
                          || ($a->{ts} // '') cmp ($b->{ts} // '') } @{ $ex->{rows} };
        my %sev;
        $sev{ $_->{severity} // 'info' }++ for @rows;
        push @out, sprintf('Alerts this session: %d (critical %d, warn %d, info %d)',
                           scalar @rows, $sev{critical} // 0, $sev{warn} // 0, $sev{info} // 0);
        for my $r (@rows[0 .. ($#rows < $SHOW - 1 ? $#rows : $SHOW - 1)]) {
            push @out, sprintf('  %s %s %s: %s', $r->{severity} // 'info', $r->{rule} // '?', $r->{alert_id},
                               watch::alerts::text_for($ctx, $r->{rule} // ''));
        }
        push @out, sprintf('  (+%d more)', @rows - $SHOW) if @rows > $SHOW;
    }
    my ($counts, $sessions) = week_counts($ctx);
    push @out, @$counts
        ? 'Alerts, last 7 days: ' . join(', ', map { "$_->[0] $_->[1]" } @$counts) . " ($sessions sessions)"
        : 'Alerts, last 7 days: none';
    push @out, stash_lines($ctx);
    my $last = last_row_ts($ctx);
    push @out, 'Last watcher row: ' . ($last // 'none');
    return \@out;
}

# C-STORE D4/D10 (MOD-SPEC §5.8): the stashes kept after a real mismatch
# (`pending/*.mismatch.md`, never deleted by the plugin), and the stashes the cross-session
# finish cannot reach because their session left no per-process record
# (<root>/.sessions/by-pid/*.{live,ended}-<sid8>.json). Counts and sid8s only; one line
# each, shown only when the count is not zero. Read-only (F2-5: core writes these files).
our $STASH_SIDS = 5;
sub stash_lines {
    my ($ctx) = @_;
    my $w = $ctx->{watch};
    my %rec;
    for my $f (watch::io::list_dir(($ctx->{root} // '') . '/.sessions/by-pid')) {
        $rec{$1} = 1 if $f =~ /\A[0-9]+-[0-9]+\.(?:live|ended)-([0-9A-Za-z-]{1,8})\.json\z/;
    }
    my $own = $ctx->{sid} // '';
    my ($kept, $kept_own, @unreached) = (0, 0);
    for my $sid (watch::io::list_dir($w)) {
        next unless $sid =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/ && -d "$w/$sid/pending";
        my ($k, $open) = (0, 0);
        for my $p (watch::io::list_dir("$w/$sid/pending")) {
            if ($p =~ /\.(?:post|mod)\.mismatch\.md\z/) { $k++ }
            elsif ($p =~ /\.(?:post|mod)\.md\z/) { $open++ }
        }
        $kept += $k;
        $kept_own += $k if $sid eq $own;
        push @unreached, substr($sid, 0, 8) if $open && $sid ne $own && !$rec{ substr($sid, 0, 8) };
    }
    my @o;
    push @o, sprintf('Stashes kept after a copy mismatch: %d (this session %d); the plugin never deletes them',
                     $kept, $kept_own) if $kept;
    if (@unreached) {
        my @show = @unreached[0 .. ($#unreached < $STASH_SIDS - 1 ? $#unreached : $STASH_SIDS - 1)];
        push @o, sprintf('Stashes no other session can finish (their session left no process record): %d session%s (%s%s)',
                         scalar @unreached, (@unreached == 1 ? '' : 's'), join(', ', @show),
                         (@unreached > @show ? sprintf(', +%d more', @unreached - @show) : ''));
    }
    return @o;
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
        for my $r (@{ watch::io::read_jsonl($p) }) {
            next unless ($r->{ev} // '') eq 'alert';
            my $t = watch::io::parse_iso($r->{ts});
            next unless defined $t && $t >= $cut;
            $n{ $r->{rule} // '?' }++;
            $s{$sid} = 1;
        }
    }
    return ([ map { [$_, $n{$_}] } sort keys %n ], scalar keys %s);
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

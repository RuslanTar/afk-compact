package watch::status;
# lib/watch/status.pm: the watcher's lines in `status` (MOD-SPEC §11, WATCH
# §7.2): open alerts for this session and the last 7 days' counts by rule.
# Owner: WP-watch. Fixed texts, ids and counts only; never content.
use strict;
use warnings;
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
    my $last = last_row_ts($ctx);
    push @out, 'Last watcher row: ' . ($last // 'none');
    return \@out;
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

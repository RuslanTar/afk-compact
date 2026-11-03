package watch::alerts;
# lib/watch/alerts.pm: alert rows and delivery (WATCHER-SPEC §7.1, §7.2).
# Owner: WP-watch.
#
# Every alert is one `alert {alert_id, rule, severity, key, evidence}` row in
# `<watch>/<sid>.alerts.jsonl`. The id is a stable hash of the rule and its
# key, so a later Stop never writes the same alert twice.
#
# Rows are never deleted. An alert is closed by a later `alert_closed {alert_id, rule, reason}`
# row in the same log (0.1.3: the rows an older version wrote under a rule that changed,
# lib/watch/supersede.pm, and an A-01 whose copy was saved later, lib/watch/rules.pm); a closed
# alert is not open: not counted or listed as open, not delivered, and never raised again (its id
# stays taken).
#
# Delivery by Stop `systemMessage` is built but switched to status-only until
# probe P-W2 passes (BUILD-PLAN E-17, W-Q3): in that mode nothing is printed
# and no `delivered/` marker is created; `/status` lists the alerts.
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::spec;
use watch::json;

our $DELIVERY = 'status-only';    # or 'system-message' after P-W2
my %SEV_RANK = (critical => 0, warn => 1, info => 2);

our $CLOSED = 'alert_closed';
our $LOG_RE = qr/"ev"\s*:\s*"alert(?:_closed)?"/;

# The alerts written so far: from a cache load (lib/watch/cache.pm) at Stop,
# else read from the alerts log. rows: every alert row; closed: {alert_id => reason};
# open: the rows not closed.
sub load_existing {
    my ($ctx, $C) = @_;
    my %e = (ids => {}, by_rule => {}, rows => [], closed => {}, open => []);
    my $rows = $C && ref $C->{rows} eq 'HASH' ? $C->{rows}{alerts}
             : watch::io::read_jsonl(watch::ctx::alerts_log($ctx), undef, $LOG_RE);
    my ($alerts, $closed) = split_rows($rows);
    $e{closed} = $closed;
    for my $r (@$alerts) {
        $e{ids}{ $r->{alert_id} } = 1;
        $e{by_rule}{ $r->{rule} // '' }++;
        push @{ $e{rows} }, $r;
        push @{ $e{open} }, $r unless exists $closed->{ $r->{alert_id} };
    }
    return \%e;
}

# split_rows(rows) -> ([alert rows], {alert_id => close reason}); read_log(path) does the same
# for one alerts log.
sub split_rows {
    my ($rows) = @_;
    my (@a, %c);
    for my $r (@{ $rows || [] }) {
        my $ev = $r->{ev} // '';
        next unless defined $r->{alert_id} && !ref $r->{alert_id};
        if ($ev eq 'alert') { push @a, $r }
        elsif ($ev eq $CLOSED) { $c{ $r->{alert_id} } //= (defined $r->{reason} && !ref $r->{reason}) ? $r->{reason} : 'closed' }
    }
    return (\@a, \%c);
}
sub read_log { return split_rows(watch::io::read_jsonl($_[0], undef, $LOG_RE)) }

sub alert_id {
    my ($rule, $sid, @parts) = @_;
    (my $r = lc $rule) =~ s/[^a-z0-9]//g;
    return $r . '-' . watch::io::fnv8(join('|', $rule, $sid // '', map { defined $_ ? $_ : '' } @parts));
}

# Write one alert unless its id exists. Returns the id when written.
sub raise {
    my ($ctx, $ex, %a) = @_;
    my $id = alert_id($a{rule}, $ctx->{sid}, @{ $a{id_parts} || [] });
    return undef if $ex->{ids}{$id};
    my $row = watch::ctx::row($ctx, 'alert', {
        alert_id => $id,
        rule     => $a{rule},
        severity => $a{severity},
        key      => $a{key} || { session_id => $ctx->{sid}, actor => undef, compaction_seq => undef, nonce => undef },
        evidence => $a{evidence} || {},
    }, actor => ($a{actor} // 'main'));
    return undef unless watch::ctx::write_row($ctx, watch::ctx::alerts_log($ctx), $row);
    $ex->{ids}{$id} = 1;
    $ex->{by_rule}{ $a{rule} }++;
    push @{ $ex->{rows} }, $row;
    push @{ $ex->{open} }, $row;
    push @{ $ex->{new} }, $row;
    return $id;
}

# close_alert(ctx, ex, alert row, reason): one `alert_closed` row for an open alert of this session
# (the alert row stays). Returns 1 when written.
sub close_alert {
    my ($ctx, $ex, $r, $reason) = @_;
    my $id = $r->{alert_id};
    return 0 if !defined $id || exists $ex->{closed}{$id};
    my $row = watch::ctx::row($ctx, $CLOSED, { alert_id => $id, rule => $r->{rule}, reason => $reason }, actor => 'main');
    return 0 unless watch::ctx::write_row($ctx, watch::ctx::alerts_log($ctx), $row);
    $ex->{closed}{$id} = $reason;
    $ex->{open} = [ grep { ($_->{alert_id} // '') ne $id } @{ $ex->{open} || [] } ];
    return 1;
}

sub text_for {
    my ($ctx, $rule) = @_;
    return watch::spec::alert_text($ctx->{spec}, $rule) // $rule;
}

# The text in the display form `<brand> watcher: <text> (<id>)` (handoff-spec §13). A spec
# text that itself starts with `<brand>: ` (the A-16 text, WATCHER-SPEC A-16) would show the
# name twice, so that prefix is dropped here (E-W-6, provisional; text-escalations E-T9-5).
sub shown_text {
    my ($ctx, $brand, $rule) = @_;
    my $t = text_for($ctx, $rule);
    $t =~ s/\A\Q$brand\E:\s+//;
    return $t;
}

# Stop delivery (WATCH §7.2). Returns the one JSON line to print, or undef.
# Status-only mode returns undef and touches nothing. `$deadline` (the Stop's
# hard stop, watch::io::mono clock): past it nothing more is picked; an alert
# not picked keeps no `delivered/` marker and is shown at a later Stop.
sub deliver {
    my ($ctx, $ex, $deadline) = @_;
    return undef unless $DELIVERY eq 'system-message';
    my $late = sub { return defined $deadline && watch::io::mono() >= $deadline };
    return undef if $late->();
    my $brand = $ctx->{brand} // 'plugin';
    my $dir = watch::ctx::sid_dir($ctx) . '/delivered';
    my %shown_rule;
    my $warn_shown = 0;
    for my $id (watch::io::list_dir($dir)) {
        my ($r) = grep { ($_->{alert_id} // '') eq $id } @{ $ex->{rows} };
        next unless $r;
        $shown_rule{ $r->{rule} } = 1;
        $warn_shown++ if ($r->{severity} // '') eq 'warn';
    }
    my @pick;
    for my $r (sort { $SEV_RANK{ $a->{severity} } <=> $SEV_RANK{ $b->{severity} } } @{ $ex->{rows} }) {
        last if @pick >= 3 || $late->();
        next if -e "$dir/$r->{alert_id}" || exists $ex->{closed}{ $r->{alert_id} };
        my $sev = $r->{severity} // 'info';
        next if $sev eq 'info';
        if ($sev eq 'warn') {
            next if $warn_shown >= 3 || $shown_rule{ $r->{rule} };
        }
        next unless watch::io::excl_create("$dir/$r->{alert_id}", '');
        $shown_rule{ $r->{rule} } = 1;
        $warn_shown++ if $sev eq 'warn';
        push @pick, $r;
    }
    return undef unless @pick;
    my $msg = join("\n", map { "$brand watcher: " . shown_text($ctx, $brand, $_->{rule}) . " ($_->{alert_id})" } @pick)
            . "\nDetails: /$brand:status";
    return watch::json::encode({ systemMessage => $msg });
}

1;

package watch::alerts;
# lib/watch/alerts.pm: alert rows and delivery (WATCHER-SPEC §7.1, §7.2).
# Owner: WP-watch.
#
# Every alert is one `alert {alert_id, rule, severity, key, evidence}` row in
# `<watch>/<sid>.alerts.jsonl`. The id is a stable hash of the rule and its
# key, so a later Stop never writes the same alert twice.
#
# Delivery by Stop `systemMessage` is built but switched to status-only until
# probe P-W2 passes (BUILD-PLAN E-17, W-Q3): in that mode nothing is printed
# and no `delivered/` marker is created; `/status` lists the alerts.
use strict;
use warnings;
use watch::ctx;
use watch::io;
use watch::spec;
use watch::json;

our $DELIVERY = 'status-only';    # or 'system-message' after P-W2
my %SEV_RANK = (critical => 0, warn => 1, info => 2);

# The alerts written so far: from a cache load (lib/watch/cache.pm) at Stop,
# else read from the alerts log.
sub load_existing {
    my ($ctx, $C) = @_;
    my %e = (ids => {}, by_rule => {}, rows => []);
    my $rows = $C && ref $C->{rows} eq 'HASH' ? $C->{rows}{alerts}
             : watch::io::read_jsonl(watch::ctx::alerts_log($ctx), undef, qr/"ev"\s*:\s*"alert"/);
    for my $r (@$rows) {
        next unless ($r->{ev} // '') eq 'alert' && defined $r->{alert_id};
        $e{ids}{ $r->{alert_id} } = 1;
        $e{by_rule}{ $r->{rule} // '' }++;
        push @{ $e{rows} }, $r;
    }
    return \%e;
}

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
    push @{ $ex->{new} }, $row;
    return $id;
}

sub text_for {
    my ($ctx, $rule) = @_;
    return watch::spec::alert_text($ctx->{spec}, $rule) // $rule;
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
        next if -e "$dir/$r->{alert_id}";
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
    my $msg = join("\n", map { "$brand watcher: " . text_for($ctx, $_->{rule}) . " ($_->{alert_id})" } @pick)
            . "\nDetails: /$brand:status";
    return watch::json::encode({ systemMessage => $msg });
}

1;

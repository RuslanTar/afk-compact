# watch.status_lines (MOD-SPEC §11, WATCH §7.2): this session's open alerts
# (critical first, fixed texts, ids only) and the last 7 days' counts by rule.
my $other = '0d0d0d0d-4444-4444-8444-444444444444';
my $a = sub { my ($t, $rule, $sev, $id) = @_;
              return T::row('alert', $t, writer => 'classic', rule => $rule, severity => $sev, alert_id => $id,
                            key => { session_id => $T::SID }, evidence => {}) };
{
    files => [
        { path => '$WATCH/$SID.alerts.jsonl',
          jsonl => [ $a->(1, 'A-05', 'warn', 'a05-00000001'), $a->(2, 'A-15', 'info', 'a15-00000002'),
                     $a->(3, 'A-01', 'critical', 'a01-00000003') ] },
        { path => "\$WATCH/$other.alerts.jsonl",
          jsonl => [ $a->(-86400, 'A-01', 'critical', 'a01-00000004'), $a->(-10 * 86400, 'A-09', 'warn', 'a09-00000005') ] },
        { path => '$WATCH/$SID.classic.jsonl', jsonl => [ T::row('sweep', 5, writer => 'classic') ] },
    ],
    steps => [ { call => 'status', at => 60 } ],
    expect => sub {
        my ($E) = @_;
        my ($l) = $E->outputs;
        $E->ok(ref $l eq 'ARRAY', 'lines returned');
        my $all = join("\n", @$l);
        $E->ok(scalar($l->[0] =~ /\AWatcher: shadow; alerts are shown here only/), 'mode line: status-only');
        $E->ok(scalar($all =~ /^Alerts this session: 3 \(critical 1, warn 1, info 1\)$/m), 'session counts');
        $E->ok(scalar($l->[2] =~ /\A  critical A-01 a01-00000003: test text 01\z/), 'critical first, fixed text');
        $E->ok(scalar($all =~ /^Alerts, last 7 days: A-01 2, A-05 1, A-15 1 \(2 sessions\)$/m), '7-day counts (the 10-day-old row excluded)');
        $E->ok(scalar($all =~ /^Last watcher row: 2026-10-21T14:00:05\.000\+03:00$/m), 'last watcher row');
    },
};

package watch::supersede;
# lib/watch/supersede.pm: 0.1.3 closes the alert rows an older version wrote under a rule that
# changed in 0.1.3 (A-01, A-05, A-11 and the hookless A-15; lib/watch/rules.pm) when the rule as
# it is now would not raise them. Owner: WP-watch.
#
# Store-wide, at a main Stop in the time left after delivery (watch.pm on_stop): every
# session's alerts log is checked once, and again whenever it changed since (a process of an
# older version still running writes more). `<watch>/<sid>/superseded-0.1.3` keeps the log
# size checked last and the version that checked it (a version that wrote the rows itself closes
# none of them: older below). A row is closed by appending `alert_closed {alert_id, rule,
# reason: "superseded: rule changed in 0.1.3"}` to the same log; rows are never deleted, and a
# closed alert is not open (lib/watch/alerts.pm). One run at a time (flock on
# <watch>/.supersede.lock); at the Stop's hard stop it ends, and the next Stop goes on from the
# logs not yet checked.
#
# The re-check uses what the session's own files recorded: the boundary record the sweep row
# kept (its time and whether a PostCompact row or dispatch was joined), the session's first
# row, its dispatch records and rollup, and its background slots and task output files. A row
# that cannot be tied to its compaction or item stays open.
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::json;
use watch::alerts;
use watch::rules;

our $RULE_V = '0.1.3';
our $REASON = 'superseded: rule changed in 0.1.3';
our $MARK = 'superseded-0.1.3';
my %RULES = map { $_ => 1 } qw(A-01 A-05 A-11 A-15);
my $SID_RE = qr/\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/;

# older(row's plugin_version, running version) -> 1 when the row was written before 0.1.3 and by
# an older version than the one running (or with no version): a row this version wrote itself
# is never re-checked here.
sub older {
    my ($v, $running) = @_;
    return 1 unless defined $v && !ref $v && $v =~ /\A[0-9]+\.[0-9]+\.[0-9]+/;
    return 0 unless _vcmp($v, $RULE_V) < 0;
    return 1 unless defined $running && !ref $running && $running =~ /\A[0-9]+\.[0-9]+\.[0-9]+/;
    return _vcmp($v, $running) < 0 ? 1 : 0;
}
sub _vcmp {
    my @x = $_[0] =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)/;
    my @y = $_[1] =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)/;
    for my $i (0 .. 2) { return $x[$i] <=> $y[$i] if $x[$i] != $y[$i] }
    return 0;
}

sub _true { my $v = shift; $v = $$v if ref $v eq 'SCALAR'; return (defined $v && !ref $v && ($v eq '1' || $v eq 'true')) ? 1 : 0 }

# run(ctx) -> the number of rows closed. ctx->{_deadline} (watch::io::mono) bounds it:
# watch::rules::tick dies "hard-stop\n" past it.
sub run {
    my ($ctx) = @_;
    my $w = $ctx->{watch};
    return 0 unless defined $w && !ref $w && -d $w && !-l $w;
    my ($lock) = watch::io::open_locked("$w/.supersede.lock");
    return 0 unless $lock;
    my $n = 0;
    my $run = $ctx->{plugin_version};
    $run = 'unknown' unless defined $run && !ref $run && $run =~ /\A[0-9A-Za-z.+-]{1,32}\z/;
    for my $f (watch::io::list_dir($w)) {
        next unless $f =~ /\A(.+)\.alerts\.jsonl\z/;
        my $sid = $1;
        next unless $sid =~ $SID_RE;
        my $p = "$w/$f";
        next if -l $p;
        my @st = stat $p or next;
        my $mark = "$w/$sid/$MARK";
        next if -l $mark;
        # unchanged since the last check by this version: the mark holds the log's size and the
        # version that checked it
        my $done = sprintf('%d %s', $st[7], $run);
        my $was = -f $mark ? (watch::io::slurp($mark, 128) // '') : '';
        $was =~ s/\s+\z//;
        next if $was eq $done;
        watch::rules::tick($ctx);
        $n += session($ctx, $sid, $p);
        my @now = stat $p;
        watch::io::write_atomic($mark, sprintf("%d %s\n", $now[7] // $st[7], $run));
    }
    close $lock;
    return $n;
}

# session(ctx, sid, alerts log) -> rows closed in that log.
sub session {
    my ($ctx, $sid, $p) = @_;
    my ($alerts, $closed) = watch::alerts::read_log($p);
    my @cand = grep { $RULES{ $_->{rule} // '' } && !exists $closed->{ $_->{alert_id} } && older($_->{plugin_version}, $ctx->{plugin_version}) } @$alerts;
    return 0 unless @cand;
    my $sc = { %$ctx, sid => $sid, payload => {} };
    delete @$sc{qw(sid_dir _task_dirs)};
    my $K = { sc => $sc };
    my ($n, %seen) = (0);
    for my $r (@cand) {
        next if $seen{ $r->{alert_id} }++;
        watch::rules::tick($ctx);
        next unless superseded($K, $r);
        my $row = watch::ctx::row($sc, $watch::alerts::CLOSED, { alert_id => $r->{alert_id}, rule => $r->{rule}, reason => $REASON },
                                  actor => 'main');
        $n++ if watch::ctx::write_row($sc, $p, $row);
    }
    return $n;
}

# superseded(K, alert row) -> 1 when the rule as it is now would not raise it.
sub superseded {
    my ($K, $r) = @_;
    my $rule = $r->{rule} // '';
    my $ev = ref $r->{evidence} eq 'HASH' ? $r->{evidence} : {};
    if ($rule eq 'A-11') {
        # an item with a known output path is checked as before
        return 0 if _true($ev->{output_known});
        return _a11_unchecked($K, $r);
    }
    my $S = _session($K);
    if ($rule eq 'A-05' && ($ev->{source} // '') eq 'rollup') {
        # no swept boundary (the P-only path): only the idle skip applies
        my $nonce = ref $r->{key} eq 'HASH' ? $r->{key}{nonce} : undef;
        return 0 unless defined $nonce && !ref $nonce && $nonce =~ /\A[0-9a-f]{8}\z/;
        return watch::rules::idle_compaction($S, { idle => watch::rules::rollup_idle($S->{rollup}{$nonce}), D => $S->{disp}{$nonce} });
    }
    # by alert id: an A-15 other than the hookless one (version_change, trigger, arm) has other id
    # parts, never matches, and stays open
    my $B = _bounds($K)->{ $r->{alert_id} } // return 0;
    my $joined = defined $B->{join} && !ref $B->{join};
    return 1 if watch::rules::history_boundary($B->{_t}, _true($B->{postcompact}), $joined, _obs($K));
    return 0 unless $rule eq 'A-05';
    my $nonce = $B->{nonce};
    my $roll = defined $nonce && !ref $nonce ? $S->{rollup}{$nonce} : undef;
    my $D = ($joined && defined $nonce && !ref $nonce) ? $S->{disp}{$nonce} : undef;
    return watch::rules::idle_compaction($S, { idle => (watch::rules::rollup_idle($roll) // $B->{idle}), D => $D,
                                               B => { ts_epoch => $B->{_t} } });
}

sub _obs { my ($K) = @_; $K->{obs} = [ watch::rules::observed_from($K->{sc}) ] unless $K->{obs}; return $K->{obs}[0] }

sub _session { my ($K) = @_; return $K->{S} //= watch::rules::load_session($K->{sc}) }

# The boundary records the session's sweep rows kept, by the alert ids A-01, A-05 and the
# hookless A-15 take for that compaction (rules.pm: id parts `b:<uuid or line>`); the last
# record of a boundary counts.
sub _bounds {
    my ($K) = @_;
    return $K->{bounds} if $K->{bounds};
    my $sc = $K->{sc};
    my %by;
    my $rows = watch::io::read_jsonl(watch::ctx::classic_log($sc), undef, qr/"ev"\s*:\s*"sweep"/);
    for my $row (@$rows) {
        next unless ($row->{ev} // '') eq 'sweep' && ref $row->{boundaries} eq 'ARRAY';
        for my $b (@{ $row->{boundaries} }) {
            next unless ref $b eq 'HASH';
            my $k = $b->{uuid} // $b->{line};
            next unless defined $k && !ref $k;
            $b->{_t} = watch::io::parse_iso($b->{ts});
            $by{ watch::alerts::alert_id('A-01', $sc->{sid}, "b:$k") } = $b;
            $by{ watch::alerts::alert_id('A-05', $sc->{sid}, "b:$k") } = $b;
            $by{ watch::alerts::alert_id('A-15', $sc->{sid}, "b:$k", 'hookless') } = $b;
        }
    }
    return $K->{bounds} = \%by;
}

# A-11 without a known output path: the rule now checks such an item only when it is a shell
# whose task output file exists (rules.pm task_output). The item is found by its alert id among
# the session's background slots and task output files; one that is not found, is not a shell
# or has no such file is not checked, so its row is closed. When the file exists the rule
# checks it, and whether it had moved by the alert's time is not known: the row stays open.
sub _a11_unchecked {
    my ($K, $r) = @_;
    my $sc = $K->{sc};
    my $items = $K->{a11} //= do {
        my %m;
        for my $s (@{ _session($K)->{bg} }) {
            for my $t (@{ $s->{tasks} }) {
                next unless defined $t->{id} && !ref $t->{id};
                $m{ watch::alerts::alert_id('A-11', $sc->{sid}, $t->{id}) } = $t;
            }
        }
        for my $d (watch::rules::task_dirs($sc)) {
            for my $f (watch::io::list_dir($d)) {
                next unless $f =~ /\A([0-9A-Za-z_-]{1,64})\.output\z/;
                my $id = $1;
                # not listed any more: Claude Code names a background shell `b` + 8 characters
                # (a workflow `w`, a teammate `t`, a monitor `s`, an agent `a`)
                $m{ watch::alerts::alert_id('A-11', $sc->{sid}, $id) } //= { id => $id, type => ($id =~ /\Ab[0-9a-z]{8}\z/ ? 'shell' : 'other') };
            }
        }
        \%m;
    };
    my $t = $items->{ $r->{alert_id} } // return 1;
    return defined watch::rules::task_output($sc, $t) ? 0 : 1;
}

1;

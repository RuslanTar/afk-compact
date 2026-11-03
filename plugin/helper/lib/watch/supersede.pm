package watch::supersede;
# lib/watch/supersede.pm: closes the alert rows an older version wrote under a rule that changed
# since (A-01, A-05, A-11 and the hookless A-15 in 0.1.3; A-09 and A-27 in 0.1.4; lib/watch/rules.pm)
# when the rule as it is now would not raise them. Owner: WP-watch.
#
# Store-wide, at a main Stop in the time left after delivery (watch.pm on_stop): every
# session's alerts log is checked once, and again whenever it changed since (a process of an
# older version still running writes more). `<watch>/<sid>/superseded` keeps the log size checked
# last and the highest version that checked it (0.1.3's `superseded-0.1.3` reads the same way);
# a version below the mark's never overwrites it. A row is checked only under the rules changed
# after the version that wrote it, up to the running one (%CHANGED; a version that wrote the
# rows itself closes none of them: older below). A row is closed by appending `alert_closed
# {alert_id, rule, reason: "superseded: rule changed in <the rule's version>"}` to the same log;
# rows are never deleted, and a closed alert is not open (lib/watch/alerts.pm). The mark records
# the size read before the check plus the bytes this run appended (0.1.4), so a row an older
# process appends meanwhile leaves the size different and the next Stop checks again. One run at
# a time (flock on <watch>/.supersede.lock); at the Stop's hard stop it ends, and the next Stop
# goes on from the logs not yet checked.
#
# The re-check uses what the session's own files recorded: the boundary record the sweep row
# kept (its time, whether a PostCompact row or dispatch was joined, its idle notice), the
# session's first row, its dispatch records and rollup, its copies and copy rows, its background
# slots, task output files and the output paths its session state kept. A row that cannot be tied
# to its compaction, continue or item stays open.
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::json;
use watch::alerts;
use watch::rules;
use watch::shape;

# The version each re-checked rule last changed in.
our %CHANGED = ('A-01' => '0.1.3', 'A-05' => '0.1.3', 'A-11' => '0.1.3', 'A-15' => '0.1.3',
                'A-09' => '0.1.4', 'A-27' => '0.1.4');
our $MARK = 'superseded';
our $MARK_013 = 'superseded-0.1.3';
my $SID_RE = qr/\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/;
my $V_RE = qr/\A[0-9]+\.[0-9]+\.[0-9]+/;

sub reason { my ($rule) = @_; return "superseded: rule changed in $CHANGED{$rule}" }

# older(row's plugin_version, running version, the rule's version) -> 1 when the row was written
# before its rule changed and by an older version than the one running (or with no version), and
# the running version has that change: a row this version wrote itself is never re-checked here.
# An unknown running version counts as the newest.
sub older {
    my ($v, $running, $rule_v) = @_;
    $rule_v //= '0.1.3';
    my $run_ok = defined $running && !ref $running && $running =~ $V_RE;
    return 0 if $run_ok && _vcmp($running, $rule_v) < 0;
    return 1 unless defined $v && !ref $v && $v =~ $V_RE;
    return 0 unless _vcmp($v, $rule_v) < 0;
    return 1 unless $run_ok;
    return _vcmp($v, $running) < 0 ? 1 : 0;
}
sub _vcmp {
    my @x = $_[0] =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)/;
    my @y = $_[1] =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)/;
    for my $i (0 .. 2) { return $x[$i] <=> $y[$i] if $x[$i] != $y[$i] }
    return 0;
}

# _mark(sid dir) -> (size, version) the log was checked at last, or ().
sub _mark {
    my ($d) = @_;
    for my $m ($MARK, $MARK_013) {
        my $p = "$d/$m";
        next if -l $p || !-f $p;
        my $was = watch::io::slurp($p, 128) // '';
        my ($n, $v) = $was =~ /\A([0-9]+)(?:\s+(\S+))?/ or next;
        # 0.1.3's own mark: checked by 0.1.3 (its name says so) unless it names its version
        $v //= '0.1.3' if $m eq $MARK_013;
        return ($n, $v);
    }
    return ();
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
    my $known = $run =~ $V_RE ? 1 : 0;
    for my $f (watch::io::list_dir($w)) {
        next unless $f =~ /\A(.+)\.alerts\.jsonl\z/;
        my $sid = $1;
        next unless $sid =~ $SID_RE;
        my $p = "$w/$f";
        next if -l $p;
        my @st = stat $p or next;
        my $mark = "$w/$sid/$MARK";
        next if -l $mark;
        # unchanged since a check by this version or a later one: the mark holds the log's size and
        # the highest version that checked it
        my ($msize, $mv) = _mark("$w/$sid");
        my $mvs = (defined $mv && $mv =~ $V_RE) ? $mv : '0.1.3';
        my $higher = ($known && defined $mv && _vcmp($mvs, $run) > 0) ? 1 : 0;
        next if defined $msize && $msize == $st[7] && ($known ? _vcmp($mvs, $run) >= 0 : (defined $mv && $mv eq $run));
        watch::rules::tick($ctx);
        my ($closed, $bytes) = session($ctx, $sid, $p);
        $n += $closed;
        # the size read before the check plus what this run appended: anything another process
        # appended meanwhile leaves the size different, and the next Stop checks again. A later
        # version's mark stays.
        watch::io::write_atomic($mark, sprintf("%d %s\n", $st[7] + $bytes, $run)) unless $higher;
    }
    close $lock;
    return $n;
}

# session(ctx, sid, alerts log) -> (rows closed in that log, bytes this run appended to it).
sub session {
    my ($ctx, $sid, $p) = @_;
    my ($alerts, $closed) = watch::alerts::read_log($p);
    my @cand = grep { my $rv = $CHANGED{ $_->{rule} // '' };
                      defined $rv && !exists $closed->{ $_->{alert_id} } && older($_->{plugin_version}, $ctx->{plugin_version}, $rv) } @$alerts;
    return (0, 0) unless @cand;
    my $sc = { %$ctx, sid => $sid, payload => {} };
    delete @$sc{qw(sid_dir _task_dirs _obs)};
    my $K = { sc => $sc };
    my ($n, $bytes, %seen) = (0, 0);
    for my $r (@cand) {
        next if $seen{ $r->{alert_id} }++;
        watch::rules::tick($ctx);
        next unless superseded($K, $r);
        my $row = watch::ctx::row($sc, $watch::alerts::CLOSED, { alert_id => $r->{alert_id}, rule => $r->{rule}, reason => reason($r->{rule}) },
                                  actor => 'main');
        next unless watch::ctx::write_row($sc, $p, $row);
        $n++;
        $bytes += length(watch::json::encode($row)) + 1;
    }
    return ($n, $bytes);
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
    return _a09($K, $r) if $rule eq 'A-09';
    return _a27($K, $r) if $rule eq 'A-27';
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
                                               B => { ts_epoch => $B->{_t}, idle_notice => $B->{idle_notice} } });
}

# A-09 (0.1.4): the 0.1.4 ledger_diff re-run on the compaction's saved copy and the previous own copy
# of the same slot (the pairing PostCompact's previous_summary made: the newest copy saved before
# the compaction's PostCompact row, another nonce). Closed when no U/D/X id is lost under the rule
# now; open when the row compared against the transcript, or either copy cannot be found or read.
sub _a09 {
    my ($K, $r) = @_;
    my $sc = $K->{sc};
    my $ev = ref $r->{evidence} eq 'HASH' ? $r->{evidence} : {};
    return 0 if ($ev->{ledger_src} // '') ne 'copy';
    my $nonce = ref $r->{key} eq 'HASH' ? $r->{key}{nonce} : undef;
    return 0 unless defined $nonce && !ref $nonce && $nonce =~ /\A[0-9a-f]{8}\z/;
    my $main = (ref $r->{key} eq 'HASH' && ($r->{key}{actor} // '') eq 'main') ? 1 : 0;
    require watch::hooks;
    my $rows = $K->{copy_rows} //= watch::hooks::_copy_rows($sc);
    my $t = sub { watch::io::parse_iso($_[0]{ts}) // 0 };
    my @ok = grep { ($_->{ev} // '') eq 'copy' && ($_->{result} // '') =~ /\A(?:saved|exists|late)\z/
                    && ($main ? ($_->{slot} // '') eq 'main' : ($_->{slot} // '') ne 'main') } @$rows;
    my ($own) = sort { $t->($a) <=> $t->($b) } grep { ($_->{nonce} // '') eq $nonce } @ok;
    return 0 unless $own;
    my ($P) = grep { ($_->{nonce_found} // '') eq $nonce } watch::rules::rows_of(_session($K), 'postcompact');
    my $at = $P ? $t->($P) : $t->($own);
    my ($prev) = sort { $t->($b) <=> $t->($a) } grep { ($_->{nonce} // '') ne $nonce && $t->($_) <= $at } @ok;
    return 0 unless $prev;
    my @text;
    for my $c ($own, $prev) {
        my $rel = watch::hooks::_attributed_path($rows, $c->{id6}) // $c->{rel_path};
        return 0 unless defined $rel && !ref $rel && $rel !~ m{(?:\A|/)\.\.(?:/|\z)} && defined $sc->{root};
        my $body = watch::io::slurp($rel =~ m{\A/} ? $rel : "$sc->{root}/$rel", 1 << 20);
        return 0 unless defined $body;
        push @text, watch::hooks::_strip_frontmatter($body);
    }
    my $l = watch::shape::ledger_diff($text[0], $text[1], 'copy', $sc->{spec});
    return (($l->{lost_U} // 1) + ($l->{lost_D} // 1) + ($l->{lost_X} // 1)) == 0 ? 1 : 0;
}

# A-27 (0.1.4): the continue's last main boundary (the main sweep rows' boundary record with the
# highest line before the continue's line) is a history boundary or an idle compaction: closed;
# a continue that cannot be tied to a boundary stays open.
sub _a27 {
    my ($K, $r) = @_;
    my $ev = ref $r->{evidence} eq 'HASH' ? $r->{evidence} : {};
    my $line = $ev->{line};
    return 0 unless defined $line && !ref $line && $line =~ /\A[0-9]+\z/;
    _bounds($K);
    my ($B) = sort { $b->{line} <=> $a->{line} } grep { $_->{line} < $line } @{ $K->{main_b} };
    return 0 unless $B;
    my $joined = defined $B->{join} && !ref $B->{join};
    return 1 if watch::rules::history_boundary($B->{_t}, _true($B->{postcompact}), $joined, _obs($K));
    my $S = _session($K);
    my $nonce = $B->{nonce};
    my $roll = defined $nonce && !ref $nonce ? $S->{rollup}{$nonce} : undef;
    my $D = ($joined && defined $nonce && !ref $nonce) ? $S->{disp}{$nonce} : undef;
    return watch::rules::idle_compaction($S, { idle => (watch::rules::rollup_idle($roll) // $B->{idle}), D => $D,
                                               B => { ts_epoch => $B->{_t}, idle_notice => $B->{idle_notice} } });
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
    my @main;
    my $rows = watch::io::read_jsonl(watch::ctx::classic_log($sc), undef, qr/"ev"\s*:\s*"sweep"/);
    for my $row (@$rows) {
        next unless ($row->{ev} // '') eq 'sweep' && ref $row->{boundaries} eq 'ARRAY';
        for my $b (@{ $row->{boundaries} }) {
            next unless ref $b eq 'HASH';
            # the main transcript's boundaries by line (A-27 ties a continue to the last one before it)
            push @main, $b if ($row->{actor} // '') eq 'main' && defined $b->{line} && !ref $b->{line} && $b->{line} =~ /\A[0-9]+\z/;
            my $k = $b->{uuid} // $b->{line};
            next unless defined $k && !ref $k;
            $b->{_t} = watch::io::parse_iso($b->{ts});
            $by{ watch::alerts::alert_id('A-01', $sc->{sid}, "b:$k") } = $b;
            $by{ watch::alerts::alert_id('A-05', $sc->{sid}, "b:$k") } = $b;
            $by{ watch::alerts::alert_id('A-15', $sc->{sid}, "b:$k", 'hookless') } = $b;
        }
    }
    $K->{main_b} = \@main;
    return $K->{bounds} = \%by;
}

# A-11 without a known output path: the rule now checks such an item only when it has an output
# the watcher can see (rules.pm task_output: a shell's task output file, a subagent's transcript, a
# workflow's run journal), by the path the session state kept when the item was first seen
# (0.1.4), else derived now. The item is found by its alert id among the session's background slots
# and task output files; one that is not found or has no such output is not checked, so its row is
# closed. When the output exists, the row stays
# open only when the file had certainly not moved for the QUIET_S before the alert (its last
# change at or before then). A file changed since then cannot tell whether the item was quiet
# at the alert's time, and the rule never flags what it cannot check: that row is closed too.
our $QUIET_S = 900;
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
                my $type = $id =~ /\Ab[0-9a-z]{8}\z/ ? 'shell' : $id =~ /\Aa[0-9a-f]{16}\z/ ? 'subagent' : $id =~ /\Aw[0-9a-z]{8}\z/ ? 'workflow' : 'other';
                $m{ watch::alerts::alert_id('A-11', $sc->{sid}, $id) } //= { id => $id, type => $type };
            }
        }
        \%m;
    };
    my $t = $items->{ $r->{alert_id} } // return 1;
    my $st = $K->{state} //= _state($sc);
    my $kept = ref $st->{session} eq 'HASH' && ref $st->{session}{task_out} eq 'HASH' ? $st->{session}{task_out}{ $t->{id} } : undef;
    my $runs = ref $st->{carry} eq 'HASH' ? $st->{carry}{task_runs} : undef;
    my $out = (defined $kept && !ref $kept && -e $kept) ? $kept : (watch::rules::task_output($sc, $t, $runs) // return 1);
    my $mt = (stat $out)[9];
    my $at = watch::io::parse_iso($r->{ts});
    return (defined $mt && defined $at && $mt <= $at - $QUIET_S) ? 0 : 1;
}


# _state(sc) -> the session's main sweep state (its offsets file holding `session`), or {}.
sub _state {
    my ($sc) = @_;
    my $d = watch::ctx::sid_dir($sc) . '/offsets';
    for my $f (sort(watch::io::list_dir($d))) {
        next unless $f =~ /\.off\z/ && !-l "$d/$f";
        my $st = watch::io::read_json_file("$d/$f");
        return $st if ref $st eq 'HASH' && ref $st->{session} eq 'HASH';
    }
    return {};
}

1;

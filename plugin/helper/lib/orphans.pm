package orphans;
# lib/orphans.pm: the stash index and the cross-session finish.
#   <watch>/.orphans/<sid>        empty marker, made before any stash of <sid> is written
#                                 (PostCompact here, the mod after-step through $.fs.write);
#                                 unlinked by <sid>'s own reconcile once pending/ holds no
#                                 *.post.md or *.mod.md. Only an index: pending/ is the truth.
#   <watch>/.orphans/.fullscan    the backstop's resumable cursor {v, plugin_version, done,
#                                 after} (atomic write under <watch>/.orphans/.lock)
# pass(budget_ms, max_sids): another session S is finished when S is not the caller, S has a
# per-process record and none of them is live (sessions::ended), and S's reconcile.lock is
# free (taken without waiting); the liveness is checked again under that lock (TOCTOU), then
# reconcile runs for S in final mode in S's context, every row carrying finished_by. No rule
# here or in reconcile looks at a stash's age: the marker order (oldest first) only decides
# which sid is tried first within the budget, never whether one is finished.
use strict;
use warnings;
use utf8;

our $PASS_MS = 1000;      # one hook pass (SessionStart, SessionEnd, Stop)
our $MAX_SIDS = 3;        # foreign sessions finished per hook pass
our $STOP_MIN_LEFT_MS = 500;

sub dir { my $w = rc::watch(); return defined $w ? "$w/.orphans" : undef }

# mark(sid): the index marker, exclusive create (EEXIST is fine); never dies.
sub mark {
    my ($sid) = @_;
    my $d = dir() // return 0;
    return 0 unless args::valid_sid($sid);
    return eval { util::write_excl("$d/$sid", '', 0600); 1 } ? 1 : 0;
}

# stash_files(sid_dir) -> the raw stashes in sid_dir/pending/ (never the *.mismatch.* keeps)
sub stash_files {
    my ($sd) = @_;
    return grep { /\A(?:[0-9a-f]{6}|h[0-9a-f]{5}(?:-\d+)?)\.post\.md\z|\A[0-9a-f]{8}\.mod\.md\z/ } util::list_dir("$sd/pending");
}

# unmark(sid, sid_dir): the owning session's reconcile drops its marker once no stash is left.
sub unmark {
    my ($sid, $sd) = @_;
    my $d = dir() // return 0;
    return 0 unless defined $sid && -e "$d/$sid";
    return 0 if stash_files($sd);
    return unlink("$d/$sid") ? 1 : 0;
}

# Test seam (STORE_TEST_MODE only): STORE_TEST_FINISH_GOLIVE="<sid>=<src>=<dst>" copies src to
# dst between sid's eligibility check and its lock, so a case can make that session live in
# the gap (AT-ST-05 f).
sub _test_gap {
    my ($S) = @_;
    return unless util::test_mode();
    my $g = $ENV{STORE_TEST_FINISH_GOLIVE} // return;
    my ($sid, $src, $dst) = split /=/, $g, 3;
    return unless defined $dst && $sid eq $S && -f $src && !-e $dst;
    util::copy_file($src, $dst, mode => 0600);
}

# The caller's newest-first list of foreign marker sids (oldest marker first).
sub _marked {
    my ($me) = @_;
    my $d = dir() // return ();
    my @m;
    for my $f (util::list_dir($d)) {
        next if $f =~ /^\./ || $f eq $me || !args::valid_sid($f);
        my @s = stat("$d/$f");
        push @m, [$f, $s[9] // 0];
    }
    return map { $_->[0] } sort { $a->[1] <=> $b->[1] || $a->[0] cmp $b->[0] } @m;
}

# finish(S, budget_ms[, after]) -> {state: finished|live|locked|none, saved, kept, left}. `after`
# (cmd/hook.pl) runs in S's context once its reconcile is done: after(result, meta, ms left).
sub finish {
    my ($S, $budget_ms, $after) = @_;
    my $t0 = util::clock_ms();
    my $w = rc::watch() // return { state => 'none' };
    my $sd = "$w/$S";
    return { state => 'none' } unless -d "$sd/pending";
    return { state => 'live' } unless rc::root_ok('handoff_root') && sessions::ended($S);
    _test_gap($S);
    my $me8 = substr(rc::sid() // '', 0, 8);
    my $out = eval {
        lock::with("$sd/reconcile.lock", { sid => rc::sid(), actor => 'finish' }, sub {
            # TOCTOU: S may have come back (resume) between the check and the lock
            return { state => 'live' } unless sessions::ended($S);
            my $rec = sessions::records_for($S)->{newest};
            return rc::as_session($S, { finished_by => $me8, claude => ($rec ? { pid => $rec->{pid}, lstart => $rec->{pid_lstart} } : undef) }, sub {
                my $meta = _newest_meta($sd);
                my $n = reconcile::run_locked(transcript => $meta->{transcript}, cwd => $meta->{cwd}, budget_ms => $budget_ms,
                                              final => 1, cutoff => reconcile::cutoff());
                eval { $after->($n, $meta, $budget_ms - (util::clock_ms() - $t0)) } if ref $after eq 'CODE';
                return { state => 'finished', saved => $n->{saved} // 0, kept => $n->{kept} // 0, left => scalar(stash_files($sd)) };
            });
        }, wait_ms => 0, log => 0);
    };
    return $out if $out;
    return { state => (($@ // '') =~ /lock-timeout/ ? 'locked' : 'none') };
}

# The transcript and cwd of S's newest PostCompact meta (content-free .post.json).
sub _newest_meta {
    my ($sd) = @_;
    my ($best, $bt);
    for my $f (util::list_dir("$sd/pending")) {
        next unless $f =~ /\.post\.json\z/ && $f !~ /mismatch/;
        my $raw = util::read_file("$sd/pending/$f") // next;
        my $j = eval { jsonc::decode($raw) };
        next unless ref $j eq 'HASH';
        my $t = util::parse_iso($j->{ts} // '') // 0;
        ($best, $bt) = ($j, $t) if !defined $bt || $t >= $bt;
    }
    return $best || {};
}

# pass(budget_ms => N, max_sids => N, full => 0|1, after => sub) -> {finished, kept, left}: the caller's
# finish pass. Marked sids first (oldest marker first); then, when the backstop is due (the
# first pass after an install or a plugin version change) or `full` is asked, every
# <watch>/*/pending/ from the resumable cursor. The caller writes one orphan_finished row
# per finished sid to its own stream.
sub pass {
    my (%o) = @_;
    my $w = rc::watch() // return { finished => 0, kept => 0, left => 0 };
    my $me = rc::sid() // return { finished => 0, kept => 0, left => 0 };
    my $deadline = util::clock_ms() + ($o{budget_ms} // $PASS_MS);
    my $max = $o{max_sids} // $MAX_SIDS;
    my %tot = (finished => 0, kept => 0, left => 0);
    my %tried;
    my $one = sub {
        my ($S) = @_;
        return 0 if $tried{$S}++;
        my $left = $deadline - util::clock_ms();
        return 0 if $left <= 0;
        my $r = finish($S, $left, $o{after});
        return 0 unless ($r->{state} // '') eq 'finished';
        rc::emit('orphan_finished', [sid => $S, saved => $r->{saved}, kept => $r->{kept}, left => $r->{left}]);
        $tot{finished}++;
        $tot{kept} += $r->{kept};
        $tot{left} += $r->{left};
        return 1;
    };
    my $done = 0;
    for my $S (_marked($me)) {
        last if $done >= $max || util::clock_ms() >= $deadline;
        $done += $one->($S);
    }
    if (($o{full} || _fullscan_due()) && util::clock_ms() < $deadline) {
        $done += _fullscan($me, $one, $deadline, $o{full} ? undef : $max - $done, $o{full});
    }
    return \%tot;
}

sub _cursor_path { my $d = dir(); return defined $d ? "$d/.fullscan" : undef }

sub _cursor {
    my $p = _cursor_path() // return {};
    my $raw = util::read_file($p);
    my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
    return ref $j eq 'HASH' && ($j->{v} // 0) == 1 ? $j : {};
}

# Due once per plugin version (the first pass after an install or an update): stashes of a
# build that wrote no markers are found by name, not by marker.
sub _fullscan_due {
    my $c = _cursor();
    return 1 unless ($c->{plugin_version} // '') eq (ctx::version() // '');
    return $c->{done} ? 0 : 1;
}

# _fullscan(me, one, deadline, max | undef, from_start) -> sids finished. Walks <watch>/*/
# in name order from the cursor; the cursor is written after every sid under .orphans/.lock,
# so the next pass resumes where this one stopped.
sub _fullscan {
    my ($me, $one, $deadline, $max, $from_start) = @_;
    my $w = rc::watch();
    my $d = dir() // return 0;
    my $c = _cursor();
    my $fresh = ($c->{plugin_version} // '') ne (ctx::version() // '');
    my $after = ($from_start || $fresh) ? '' : ($c->{after} // '');
    my @sids = sort grep { $_ gt $after && $_ ne $me && args::valid_sid($_) && -d "$w/$_/pending" } util::list_dir($w);
    my $done = 0;
    my $last = $after;
    my $complete = 1;
    for my $S (@sids) {
        if (util::clock_ms() >= $deadline || (defined $max && $done >= $max)) { $complete = 0; last }
        $done += $one->($S) if stash_files("$w/$S");
        $last = $S;
        _write_cursor($last, 0);
    }
    _write_cursor($complete ? '' : $last, $complete);
    return $done;
}

sub _write_cursor {
    my ($after, $done) = @_;
    my $d = dir() // return;
    eval {
        lock::with("$d/.lock", { sid => rc::sid(), actor => 'finish' }, sub {
            util::write_atomic("$d/.fullscan", jsonc::encode_bytes(jsonc::obj(v => 1, plugin_version => ctx::version(),
                                                                                done => jsonc::bool($done), after => $after)) . "\n", 0600);
        }, wait_ms => 200, log => 0);
    };
}

1;

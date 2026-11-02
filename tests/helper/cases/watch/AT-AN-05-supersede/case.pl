# AT-AN-05 (0.1.3 alert noise, root decision 1; lib/watch/supersede.pm): the first watcher Stop
# of 0.1.3 re-checks the open A-01, A-05, A-11 and A-15 rows an older version wrote, in every
# session's alerts log, under the rule as it is now, and closes the ones it would not raise with
# an `alert_closed` row (reason `superseded: rule changed in 0.1.3`); rows are never deleted.
# Another session (OTHER) holds a 0.1.2 log: its sweep row kept the boundary records (one from
# before the session's first row, one after it, two joined to dispatches, idle and not), its
# dispatch records, background slots and one task output file. Kept open: the observed
# compaction's A-01 and hookless A-15, the non-idle A-05, the version_change A-15, a row 0.1.3
# wrote itself, the shells whose output file exists (one listed, one found by its id prefix),
# the item with a known output path, A-09.
# A second Stop closes nothing more; a row an older process appends later is checked again.
# `status` lists and counts only open alerts (verdict, this-session list, 7-day counts) and says
# how many were closed as superseded, only in the 7 days after.
my $OTHER = '2b2c3d4e-0000-4000-8000-00000000c0de';
my %rec = (attributed => 'main', copy => 'missing', idle => undef, line => 1, seq => 1, nonce => 'none', join => undef,
           channel => undef, postcompact => \0, precomputed => \0, trigger => 'auto');
my @b = ({ %rec, uuid => 'u-h1', ts => T::loc(100), line => 10, seq => 1 },
         { %rec, uuid => 'u-o2', ts => T::loc(1500), line => 20, seq => 2 },
         { %rec, uuid => 'u-i3', ts => T::loc(1600), line => 30, seq => 3, postcompact => \1, join => 'nonce', nonce => '1d1e0003',
           channel => 'mod-hook', copy => 'saved' },
         { %rec, uuid => 'u-n4', ts => T::loc(1700), line => 40, seq => 4, postcompact => \1, join => 'nonce', nonce => '1d1e0004',
           channel => 'mod-hook', copy => 'saved' },
         { %rec, uuid => 'u-h5', ts => T::loc(200), line => 50, seq => 5 });
my $aid = sub { watch::alerts::alert_id(@_[0], $OTHER, @_[1 .. $#_]) };
my $alert = sub {
    my ($rule, $sev, $id, %o) = @_;
    my $r = T::row('alert', 2000, writer => 'classic', sid => $OTHER, alert_id => $id, rule => $rule, severity => $sev,
                   key => { session_id => $OTHER, actor => 'main', compaction_seq => $o{seq}, nonce => ($o{nonce} // 'none') },
                   evidence => $o{evidence} || {});
    $r->{plugin_version} = $o{version} // '0.1.2';
    return $r;
};
my @old = (
    $alert->('A-01', 'critical', $aid->('A-01', 'b:u-h1'), seq => 1, evidence => { copy => 'missing', line => 10 }),
    $alert->('A-15', 'warn', $aid->('A-15', 'b:u-h1', 'hookless'), seq => 1, evidence => { hookless_boundary => \1, line => 10 }),
    $alert->('A-05', 'warn', $aid->('A-05', 'b:u-h1'), seq => 1, evidence => { band_position => 'below-target' }),
    $alert->('A-01', 'critical', $aid->('A-01', 'b:u-o2'), seq => 2, evidence => { copy => 'missing', line => 20 }),
    $alert->('A-15', 'info', $aid->('A-15', 'b:u-o2', 'hookless'), seq => 2, evidence => { hookless_boundary => \1, line => 20 }),
    $alert->('A-05', 'warn', $aid->('A-05', 'b:u-i3'), seq => 3, nonce => '1d1e0003', evidence => { band_position => 'below-target' }),
    $alert->('A-05', 'warn', $aid->('A-05', 'b:u-n4'), seq => 4, nonce => '1d1e0004', evidence => { band_position => 'below-target' }),
    $alert->('A-05', 'warn', $aid->('A-05', 'p:x'), nonce => '1d1e0005', evidence => { band_position => 'below-target', source => 'rollup' }),
    $alert->('A-15', 'warn', $aid->('A-15', 'canary'), evidence => { canary => 'version_change' }),
    $alert->('A-01', 'critical', $aid->('A-01', 'b:u-h5'), seq => 5, version => '0.1.3', evidence => { copy => 'missing', line => 50 }),
    map({ $alert->('A-11', 'warn', $aid->('A-11', $_), evidence => { output_known => \0, minutes => 90 }) } qw(tm-1 sh-d sh-x gone-1 wabcdefgh babcdefgh)),
    $alert->('A-11', 'warn', $aid->('A-11', 'sh-k'), evidence => { output_known => \1, minutes => 90 }),
    $alert->('A-09', 'warn', $aid->('A-09', 'x'), evidence => {}),
);
my %closed_want = map { $_ => 1 } ($aid->('A-01', 'b:u-h1'), $aid->('A-15', 'b:u-h1', 'hookless'), $aid->('A-05', 'b:u-h1'),
                                   $aid->('A-05', 'b:u-i3'), $aid->('A-05', 'p:x'), $aid->('A-11', 'tm-1'), $aid->('A-11', 'sh-x'),
                                   $aid->('A-11', 'gone-1'), $aid->('A-11', 'wabcdefgh'));
my $late = $alert->('A-15', 'warn', $aid->('A-15', 'b:u-h5', 'hookless'), seq => 5, evidence => { hookless_boundary => \1, line => 50 });
my $disp = sub { my ($n, $t, $idle) = @_; my $d = T::dispatch($n, $t); $d->{session_id} = $OTHER; $d->{idle} = $idle ? \1 : \0; return $d };
my @tasks = ({ id => 'tm-1', type => 'teammate', status => 'running', output_path => undef },
             { id => 'sh-d', type => 'shell', status => 'running', output_path => undef },
             { id => 'sh-x', type => 'shell', status => 'running', output_path => undef },
             { id => 'sh-k', type => 'shell', status => 'running', output_path => '/nonexistent/sh-k.output' });
my %got;
my $status = sub {
    my ($v, $at, $key) = @_;
    my $ctx = { sid => $OTHER, watch => $v->{WATCH}, root => $v->{ROOT}, plugin_root => $v->{PLUGIN}, settings => {},
                now => $T::BASE + $at, cc_tmpdir => "$v->{TMP}/cctmp" };
    $got{$key} = { lines => watch::status_lines($OTHER, { %$ctx }), verdict => watch::verdict_line($OTHER, { %$ctx }) };
};
{
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    files => [
        { path => "\$WATCH/$OTHER.classic.jsonl",
          jsonl => [ { %{ T::row('config_note', 1000, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') }, sid => $OTHER },
                     { %{ T::row('sweep', 2000, writer => 'classic') }, sid => $OTHER, file => "$OTHER.jsonl", boundaries => \@b } ] },
        { path => "\$WATCH/$OTHER.alerts.jsonl", jsonl => \@old },
        # this session's own log: an A-11 of an item it no longer knows
        { path => '$WATCH/$SID.alerts.jsonl',
          jsonl => [ { %{ T::row('alert', 50, writer => 'classic', alert_id => watch::alerts::alert_id('A-11', $T::SID, 'cur-gone'),
                                 rule => 'A-11', severity => 'warn', key => { session_id => $T::SID },
                                 evidence => { output_known => \0, minutes => 70 }) }, plugin_version => '0.1.2' } ] },
        { path => "\$WATCH/$OTHER/dispatch/1d1e0003.json", json => $disp->('1d1e0003', 1599, 1) },
        { path => "\$WATCH/$OTHER/dispatch/1d1e0004.json", json => $disp->('1d1e0004', 1699, 0) },
        { path => "\$WATCH/$OTHER/dispatch/1d1e0005.json", json => $disp->('1d1e0005', 1799, 1) },
        { path => "\$WATCH/$OTHER/bg/slot-0.json", json => { v => 1, ts => T::loc(1900), set_hash => 'h0', tasks => \@tasks } },
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/sh-d.output", text => "x\n" },
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/a1b2.output", text => "x\n" },
        # no longer listed: by Claude Code's id prefix a workflow (w) and a shell (b)
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/wabcdefgh.output", text => "x\n" },
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/babcdefgh.output", text => "x\n" },
    ],
    steps => [
        { call => 'code', code => sub { $status->($_[0], 2900, 'before') } },
        { call => 'stop', at => 3000 },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{after1} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") } ];
              $got{mark} = -f "$v->{WATCH}/$OTHER/superseded-0.1.3" ? 1 : 0;
              $status->($v, 3050, 'after');
              # the shell's output file goes away: an unchanged log is not checked again, so its
              # row stays open until the log changes
              unlink "$v->{TMP}/cctmp/claude-$</-other-proj/$OTHER/tasks/sh-d.output";
              $watch::alerts::DELIVERY = 'system-message';
          } },
        # delivery (once probe P-W2 passes) skips a closed alert: this session's only one is closed
        { call => 'stop', at => 3100, expect_output => 1 },
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'status-only' } },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{after2} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") } ];
              open(my $fh, '>>', "$v->{WATCH}/$OTHER.alerts.jsonl") or die;
              print $fh watch::json::encode($late), "\n";
              close $fh;
              # same second as the mark: the size it holds tells the change
              my $mt = (stat "$v->{WATCH}/$OTHER/superseded-0.1.3")[9];
              utime($mt, $mt, "$v->{WATCH}/$OTHER.alerts.jsonl");
          } },
        { call => 'stop', at => 3200 },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{after3} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") } ];
              $got{rows_kept} = scalar grep { ($_->{ev} // '') eq 'alert' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") };
              $status->($v, 3200 + 8 * 86400, 'week');
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @c = @{ $got{after1} || [] };
        my %c = map { ($_->{alert_id} => $_) } @c;
        $E->count(\@c, 9, 'the first Stop closes the 9 rows the rule as it is now would not raise');
        $E->is(join(',', sort grep { !$closed_want{$_} } keys %c), '', 'no other row closed');
        $E->is(join(',', sort grep { !$c{$_} } keys %closed_want), '', 'every superseded row closed');
        $E->is(scalar(grep { ($_->{reason} // '') eq 'superseded: rule changed in 0.1.3' && ($_->{sid} // '') eq $OTHER } @c), 9,
               'each with the reason, in that session');
        $E->is($got{mark}, 1, 'the log is marked checked');
        $E->count($got{after2} || [], 9, 'a second Stop closes nothing more');
        my @c3 = @{ $got{after3} || [] };
        $E->count(\@c3, 11, 'once an older process appended a row, the log is checked again');
        $E->is(join(',', sort map { $_->{alert_id} } @c3[9 .. $#c3]), join(',', sort($aid->('A-11', 'sh-d'), $late->{alert_id})),
               'the late hookless A-15 of a history boundary, and the shell whose file went away') if @c3 >= 11;
        my ($o2) = $E->outputs;
        $E->is($o2, undef, 'the closed alert is not delivered');
        $E->is($got{rows_kept}, scalar(@old) + 1, 'no alert row deleted');
        my @own = grep { ($_->{ev} // '') eq 'alert_closed' } $E->rows('alerts');
        $E->count(\@own, 1, "this session's own old row is closed too");
        my $b = $got{before} || {};
        $E->is($b->{verdict}, 'attention: 17 open alerts (A-01, A-05, A-09, A-11, A-15); no compactions this session',
               'before: the verdict counts the old rows');
        my $a = $got{after} || {};
        $E->is($a->{verdict}, 'attention: 8 open alerts (A-01, A-05, A-09, A-11, A-15); no compactions this session',
               'after: only the open rows');
        my @l = @{ $a->{lines} || [] };
        $E->is(scalar(grep { /\AAlerts this session: 9 \(critical 2, warn 6, info 1\)\z/ } @l), 1, 'the list counts the open rows')
            or $E->ok(0, "lines: @l");
        $E->is(scalar(grep { /\A  \S+ \S+ (\S+):/ && $closed_want{$1} } @l), 0, 'no closed row listed');
        $E->is(scalar(grep { /\AAlerts, last 7 days: A-01 2, A-05 1, A-09 1, A-11 3, A-15 2 \(1 sessions\)\z/ } @l), 1,
               'the 7-day counts leave the closed rows out');
        $E->is(scalar(grep { $_ eq 'Alerts closed as superseded (the rule changed in 0.1.3; rows kept): 10' } @l), 1,
               'one line counts the superseded rows, store-wide');
        $E->is(scalar(grep { /superseded/ } @{ ($got{week} || {})->{lines} || [] }), 0, 'not shown 8 days later');
        # the Stop reads its own alerts log through the watch cache: the close row is kept there
        my @cache = grep { ($_->{s} // '') eq 'alerts' && ($_->{r}{ev} // '') eq 'alert_closed' }
                    @{ watch::io::read_jsonl($E->var('WATCH') . '/' . $E->var('SID') . '/watch-cache/rows.jsonl') };
        $E->count(\@cache, 1, 'the watch cache keeps the close row');
    },
};

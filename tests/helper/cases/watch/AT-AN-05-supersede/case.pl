# AT-AN-05 (0.1.3 alert noise, root decision 1; lib/watch/supersede.pm): the first watcher Stop
# of 0.1.3 re-checks the open A-01, A-05, A-11 and A-15 rows an older version wrote, in every
# session's alerts log, under the rule as it is now, and closes the ones it would not raise with
# an `alert_closed` row (reason `superseded: rule changed in 0.1.3`); rows are never deleted.
# Another session (OTHER) holds a 0.1.2 log: its sweep row kept the boundary records (one from
# before the session's first row, one after it, two joined to dispatches, idle and not), its
# dispatch records, background slots and one task output file. Kept open: the observed
# compaction's A-01 and hookless A-15, the non-idle A-05, the version_change A-15, a row 0.1.3
# wrote itself, the listed shell whose output file had not changed for the 15 minutes before the
# alert, the item with a known output path, A-09. Closed too: the listed shell whose output file
# changed 5 minutes before its alert, and the shell found by its id prefix whose output file
# changed after the alert (whether either was quiet then cannot be told, and 0.1.3 never flags
# what it cannot check).
# A second Stop closes nothing more; a row an older process appends later is checked again. A
# later version (a Stop as 0.1.4) closes no row 0.1.3 wrote itself, even one 0.1.3's rule would
# not raise now.
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
    map({ $alert->('A-11', 'warn', $aid->('A-11', $_), evidence => { output_known => \0, minutes => 90 }) } qw(tm-1 sh-d sh-x sh-w gone-1 wabcdefgh babcdefgh)),
    $alert->('A-11', 'warn', $aid->('A-11', 'sh-k'), evidence => { output_known => \1, minutes => 90 }),
    $alert->('A-09', 'warn', $aid->('A-09', 'x'), evidence => {}),
);
my %closed_want = map { $_ => 1 } ($aid->('A-01', 'b:u-h1'), $aid->('A-15', 'b:u-h1', 'hookless'), $aid->('A-05', 'b:u-h1'),
                                   $aid->('A-05', 'b:u-i3'), $aid->('A-05', 'p:x'), $aid->('A-11', 'tm-1'), $aid->('A-11', 'sh-x'),
                                   $aid->('A-11', 'sh-w'), $aid->('A-11', 'gone-1'), $aid->('A-11', 'wabcdefgh'), $aid->('A-11', 'babcdefgh'));
my $late = $alert->('A-15', 'warn', $aid->('A-15', 'b:u-h5', 'hookless'), seq => 5, evidence => { hookless_boundary => \1, line => 50 });
my $disp = sub { my ($n, $t, $idle) = @_; my $d = T::dispatch($n, $t); $d->{session_id} = $OTHER; $d->{idle} = $idle ? \1 : \0; return $d };
my @tasks = ({ id => 'tm-1', type => 'teammate', status => 'running', output_path => undef },
             { id => 'sh-d', type => 'shell', status => 'running', output_path => undef },
             { id => 'sh-x', type => 'shell', status => 'running', output_path => undef },
             { id => 'sh-w', type => 'shell', status => 'running', output_path => undef },
             { id => 'sh-k', type => 'shell', status => 'running', output_path => '/nonexistent/sh-k.output' });
# the Stops run as 0.1.3 (the cases' own manifest says 0.1.0): rows of the running version are never re-checked
my $v013 = { plugin_version => '0.1.3' };
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
        # last changed 16 minutes before its alert (at 2000): certainly quiet then
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/sh-d.output", text => "x\n", mtime => $T::BASE + 2000 - 960 },
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/a1b2.output", text => "x\n" },
        # last changed 5 minutes before its alert: not quiet for the 15 minutes before it
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/sh-w.output", text => "x\n", mtime => $T::BASE + 2000 - 300 },
        # no longer listed: by Claude Code's id prefix a workflow (w) and a shell (b); the shell's
        # file changed after its alert (written now)
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/wabcdefgh.output", text => "x\n" },
        { path => "\$TMP/cctmp/claude-$</-other-proj/$OTHER/tasks/babcdefgh.output", text => "x\n" },
    ],
    steps => [
        { call => 'code', code => sub { $status->($_[0], 2900, 'before') } },
        # a Stop of 0.1.2 itself (the rows are its own) closes nothing and marks the logs checked
        # by 0.1.2 only
        { call => 'stop', at => 2950, ctx => { plugin_version => '0.1.2' } },
        { call => 'code', code => sub {
              $got{after0} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$_[0]{WATCH}/$OTHER.alerts.jsonl") } ];
          } },
        { call => 'stop', at => 3000, ctx => $v013 },
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
        { call => 'stop', at => 3100, expect_output => 1, ctx => $v013 },
        { call => 'code', code => sub { $watch::alerts::DELIVERY = 'status-only' } },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{after2} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") } ];
              open(my $fh, '>>', "$v->{WATCH}/$OTHER.alerts.jsonl") or die;
              print $fh watch::json::encode($late), "\n";
              close $fh;
              # in the same second as the mark: its size tells the change
              my $mt = (stat "$v->{WATCH}/$OTHER/superseded-0.1.3")[9];
              utime($mt, $mt, "$v->{WATCH}/$OTHER.alerts.jsonl");
          } },
        { call => 'stop', at => 3200, ctx => $v013 },
        { call => 'code', code => sub {
              my ($v) = @_;
              $got{after3} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") } ];
              $got{rows_kept} = scalar grep { ($_->{ev} // '') eq 'alert' } @{ watch::io::read_jsonl("$v->{WATCH}/$OTHER.alerts.jsonl") };
              $status->($v, 3200 + 8 * 86400, 'week');
              # 0.1.3's own A-11 of an item that is gone (0.1.3's rule would not raise it now)
              open(my $fh, '>>', "$v->{WATCH}/$OTHER.alerts.jsonl") or die;
              print $fh watch::json::encode($alert->('A-11', 'warn', $aid->('A-11', 'gone-3'), version => '0.1.3',
                                                     evidence => { output_known => \0, minutes => 90 })), "\n";
              close $fh;
          } },
        # a later version: rows 0.1.3 wrote are not re-checked under 0.1.3's rule change
        { call => 'stop', at => 3300, ctx => { plugin_version => '0.1.4' } },
        { call => 'code', code => sub {
              $got{after4} = [ grep { ($_->{ev} // '') eq 'alert_closed' } @{ watch::io::read_jsonl("$_[0]{WATCH}/$OTHER.alerts.jsonl") } ];
              $got{mark4} = watch::io::slurp("$_[0]{WATCH}/$OTHER/superseded-0.1.3", 128) // '';
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @c = @{ $got{after1} || [] };
        my %c = map { ($_->{alert_id} => $_) } @c;
        $E->count(\@c, 11, 'the first Stop closes the 11 rows the rule as it is now would not raise');
        $E->is(join(',', sort grep { !$closed_want{$_} } keys %c), '', 'no other row closed');
        $E->is(join(',', sort grep { !$c{$_} } keys %closed_want), '', 'every superseded row closed');
        $E->is(scalar(grep { ($_->{reason} // '') eq 'superseded: rule changed in 0.1.3' && ($_->{sid} // '') eq $OTHER } @c), 11,
               'each with the reason, in that session');
        $E->count($got{after0} || [], 0, '0.1.2 closes none of its own rows');
        $E->is($got{mark}, 1, 'the log is marked checked');
        $E->count($got{after2} || [], 11, 'a second Stop closes nothing more');
        my @c3 = @{ $got{after3} || [] };
        $E->count(\@c3, 13, 'once an older process appended a row, the log is checked again');
        $E->is(join(',', sort map { $_->{alert_id} } @c3[11 .. $#c3]), join(',', sort($aid->('A-11', 'sh-d'), $late->{alert_id})),
               'the late hookless A-15 of a history boundary, and the shell whose file went away') if @c3 >= 13;
        $E->ok(scalar(($got{mark4} // '') =~ / 0\.1\.4\n?\z/), 'the 0.1.4 Stop checked the log');
        $E->count($got{after4} || [], 13, '0.1.4 closes none of the rows 0.1.3 wrote (A-01 of a history boundary, A-11 of a gone item)');
        my ($o2) = $E->outputs;
        $E->is($o2, undef, 'the closed alert is not delivered');
        $E->is($got{rows_kept}, scalar(@old) + 1, 'no alert row deleted');
        my @own = grep { ($_->{ev} // '') eq 'alert_closed' } $E->rows('alerts');
        $E->count(\@own, 1, "this session's own old row is closed too");
        my $b = $got{before} || {};
        $E->is($b->{verdict}, 'attention: 18 open alerts (A-01, A-05, A-09, A-11, A-15); no compactions this session',
               'before: the verdict counts the old rows');
        my $a = $got{after} || {};
        $E->is($a->{verdict}, 'attention: 7 open alerts (A-01, A-05, A-09, A-11, A-15); no compactions this session',
               'after: only the open rows');
        my @l = @{ $a->{lines} || [] };
        $E->is(scalar(grep { /\AAlerts this session: 8 \(critical 2, warn 5, info 1\)\z/ } @l), 1, 'the list counts the open rows')
            or $E->ok(0, "lines: @l");
        $E->is(scalar(grep { /\A  \S+ \S+ (\S+):/ && $closed_want{$1} } @l), 0, 'no closed row listed');
        $E->is(scalar(grep { /\AAlerts, last 7 days: A-01 2, A-05 1, A-09 1, A-11 2, A-15 2 \(1 sessions\)\z/ } @l), 1,
               'the 7-day counts leave the closed rows out');
        $E->is(scalar(grep { $_ eq 'Alerts closed as superseded (the rule changed in 0.1.3; rows kept): 12' } @l), 1,
               'one line counts the superseded rows, store-wide');
        $E->is(scalar(grep { /superseded/ } @{ ($got{week} || {})->{lines} || [] }), 0, 'not shown 8 days later');
        # the Stop reads its own alerts log through the watch cache: the close row is kept there
        my @cache = grep { ($_->{s} // '') eq 'alerts' && ($_->{r}{ev} // '') eq 'alert_closed' }
                    @{ watch::io::read_jsonl($E->var('WATCH') . '/' . $E->var('SID') . '/watch-cache/rows.jsonl') };
        $E->count(\@cache, 1, 'the watch cache keeps the close row');
    },
};

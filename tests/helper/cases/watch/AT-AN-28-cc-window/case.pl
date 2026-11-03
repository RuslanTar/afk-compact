# AT-AN-28 (0.1.4 W-19): with no mod row (classic only) and native_window_tokens unset, the watcher's
# band thresholds take Claude Code's autoCompactWindow setting as the window, as the mod does (the
# merged settings: ~/.claude/settings.json, the project's .claude/settings.json and
# settings.local.json, the managed file; a JSON number, floored at 100,000). No setting: no
# thresholds (no band). 200000: thresholds with the triggers off for a small window (band
# triggers-off). The project's local file then names 800000: the boundary below the target raises
# A-05. A quoted "800000" is not a number: no thresholds again.
# Claude Code never compacts past the model's own window, which the watcher does not know: while the
# session's context has not been above the standard 200,000, a setting above it gives no thresholds
# (the first compactions are at 150,000; the 800,000 window counts once one was at 250,000). The
# project's files are read from the project root (CLAUDE_PROJECT_DIR) before the hook's cwd: a cwd
# in a subfolder still finds the root's settings.local.json.
my %got;
my $set = sub { my ($path, $json) = @_; return { call => 'code', code => sub { main::write_file(main::sub_vars($path, $_[0]), $json) } } };
# the Stop whose hook cwd is a subfolder of the project (the path is known once the case runs)
my $sub_stop = { call => 'stop', at => 1000, payload => {} };
my $b = sub { my ($t, $u, $pre) = @_; return (T::boundary($t, uuid => $u, trigger => 'auto', preTokens => $pre // 250000), T::summary($t + 0.1), T::prompt($t + 50)) };
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), $b->(100, 'b-none', 150000) ],
    steps => [
        { call => 'stop', at => 200 },
        $set->('$HOME/.claude/settings.json', qq({"model": "x", "autoCompactWindow": 200000}\n)),
        { call => 'append', rows => [ $b->(300, 'b-200k', 150000) ] },
        { call => 'stop', at => 400 },
        { call => 'code', code => sub { watch::io::mkdir_p("$_[0]{HOME}/work/.claude") } },
        $set->('$HOME/work/.claude/settings.local.json', qq({"autoCompactWindow": 800000}\n)),
        { call => 'append', rows => [ $b->(450, 'b-unseen', 150000) ] },
        { call => 'stop', at => 470 },
        { call => 'append', rows => [ $b->(500, 'b-800k') ] },
        { call => 'stop', at => 600 },
        $set->('$HOME/work/.claude/settings.local.json', qq({"autoCompactWindow": "800000"}\n)),
        { call => 'append', rows => [ $b->(700, 'b-quoted') ] },
        { call => 'stop', at => 800 },
        $set->('$HOME/work/.claude/settings.local.json', qq({"autoCompactWindow": 800000}\n)),
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{HOME}/work/sub");
              $ENV{CLAUDE_PROJECT_DIR} = "$v->{HOME}/work";
              $sub_stop->{payload}{cwd} = "$v->{HOME}/work/sub";
          } },
        { call => 'append', rows => [ $b->(900, 'b-subdir') ] },
        $sub_stop,
        { call => 'code', code => sub { delete $ENV{CLAUDE_PROJECT_DIR} } },
    ],
    expect => sub {
        my ($E) = @_;
        delete $ENV{CLAUDE_PROJECT_DIR};
        my %b = map { ($_->{uuid} => $_) } $E->boundaries;
        $E->is(join(',', map { ($b{$_} || {})->{band_position} // '-' } qw(b-none b-200k b-unseen b-800k b-quoted b-subdir)),
               '-,triggers-off,-,below-target,-,below-target',
               'no setting: no band; 200000: triggers off (small window); 800000 before a context above 200000: none; '
               . 'then (the project local file wins) below the target; a quoted value: none; from a subfolder cwd: the project root\'s file');
        my @a = $E->alerts('A-05');
        $E->count(\@a, 2, 'A-05 for the two compactions below the 800000 window\'s target');
        $E->is($a[0]{evidence}{target}, 400000, 'the target the 800000 window gives') if @a;
    },
};

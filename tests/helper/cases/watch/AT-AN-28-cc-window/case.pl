# AT-AN-28 (0.1.4 W-19): with no mod row (classic only) and native_window_tokens unset, the watcher's
# band thresholds take Claude Code's autoCompactWindow setting as the window, as the mod does (the
# merged settings: ~/.claude/settings.json, the project's .claude/settings.json and
# settings.local.json, the managed file; a JSON number, floored at 100,000). No setting: no
# thresholds (no band). 200000: thresholds with the triggers off for a small window (band
# triggers-off). The project's local file then names 800000: the boundary below the target raises
# A-05. A quoted "800000" is not a number: no thresholds again.
my %got;
my $set = sub { my ($path, $json) = @_; return { call => 'code', code => sub { main::write_file(main::sub_vars($path, $_[0]), $json) } } };
my $b = sub { my ($t, $u) = @_; return (T::boundary($t, uuid => $u, trigger => 'auto', preTokens => 250000), T::summary($t + 0.1), T::prompt($t + 50)) };
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), $b->(100, 'b-none') ],
    steps => [
        { call => 'stop', at => 200 },
        $set->('$HOME/.claude/settings.json', qq({"model": "x", "autoCompactWindow": 200000}\n)),
        { call => 'append', rows => [ $b->(300, 'b-200k') ] },
        { call => 'stop', at => 400 },
        { call => 'code', code => sub { watch::io::mkdir_p("$_[0]{HOME}/work/.claude") } },
        $set->('$HOME/work/.claude/settings.local.json', qq({"autoCompactWindow": 800000}\n)),
        { call => 'append', rows => [ $b->(500, 'b-800k') ] },
        { call => 'stop', at => 600 },
        $set->('$HOME/work/.claude/settings.local.json', qq({"autoCompactWindow": "800000"}\n)),
        { call => 'append', rows => [ $b->(700, 'b-quoted') ] },
        { call => 'stop', at => 800 },
    ],
    expect => sub {
        my ($E) = @_;
        my %b = map { ($_->{uuid} => $_) } $E->boundaries;
        $E->is(join(',', map { ($b{$_} || {})->{band_position} // '-' } qw(b-none b-200k b-800k b-quoted)), '-,triggers-off,below-target,-',
               'no setting: no band; 200000: triggers off (small window); 800000 (the project local file wins): below the target; a quoted value: none');
        my @a = $E->alerts('A-05');
        $E->count(\@a, 1, 'A-05 for the compaction below the 800000 window\'s target');
        $E->is($a[0]{evidence}{target}, 400000, 'the target the 800000 window gives') if @a;
    },
};

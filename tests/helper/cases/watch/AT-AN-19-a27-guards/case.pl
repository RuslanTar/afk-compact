# AT-AN-19 (0.1.4 W-2): A-27 (a plugin continue after a main boundary that no nudge drove) skips the
# boundaries A-01, A-05 and the hookless A-15 skip: one from before the session's first row (a history
# boundary: all 12 A-27 rows of the 0.1.2 log were continues after such a boundary, hours later) and an
# idle compaction (here by Claude Code's native idle notice, W-16). The boundary is swept at one Stop
# and its continue at the next, so what the first Stop learned of it is kept. A continue after an
# observed, un-nudged auto boundary still raises A-27. The last compaction is idle by the mod's
# dispatch (no notice): its boundary is swept at one Stop, its continue at the next, and what the first
# Stop learned of it (session state `bmeta`) keeps the continue quiet.
# The history boundary is swept at a Stop whose session state then loses `bmeta` (what a 0.1.3 Stop,
# which kept none, leaves): its continue is still quiet, by the boundary time the sweep put on it.
# The plugin's handoff-turn submits (each [submit-*] line of assets/handoff-turn.txt) with no ht
# record left, after the observed boundary, are no continues: no A-27 for them (the 12 A-27 rows of
# the 0.1.2 log were such submits, pre-compaction and pre-idle handoff turns).
my $nm = '9a9b0001';
my @submits = do {
    open(my $fh, '<:raw', "$T::REPO/plugin/assets/handoff-turn.txt") or die "handoff-turn.txt: $!";
    map { /\A\[submit-(?:halt|pre|idle)\] (Note from .*)\z/ ? do { (my $x = $1) =~ s/\@[a-z_]+\@/7/g; $x } : () } map { s/\r?\n\z//r } <$fh>;
};
my $submit = sub { my ($t, $text) = @_; my $r = T::continue_row($t); $r->{message}{content} = "The $T::BRAND plugin sent a message:\n$text"; return $r };
my %got;
my $notice = sub { my ($t) = @_; return { type => 'system', subtype => 'informational', content => 'Compacted while idle for 1h',
                                           level => 'info', uuid => T::uid(), sessionId => $T::SID, timestamp => T::z($t) } };
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 500, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only'),
                     T::row('postcompact', 1201, writer => 'classic', nonce_found => $nm, scope_found => 'main', verdict => 'ok', trigger => 'auto') ] },
        { path => "\$WATCH/\$SID/dispatch/$nm.json", json => { %{ T::dispatch($nm, 1199) }, idle => \1, idle_gap_s => 3600 } },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), T::boundary(100, uuid => 'b-hist', trigger => 'auto'), T::summary(100.1) ],
    steps => [
        { call => 'stop', at => 550 },
        { call => 'code', code => sub {
              my $p = "$_[0]{WATCH}/$T::SID/offsets/$T::SID.jsonl.off";
              my $st = watch::io::read_json_file($p) || {};
              $got{bmeta} = ref $st->{session}{bmeta} eq 'HASH' ? scalar(keys %{ $st->{session}{bmeta} }) : 0;
              delete $st->{session}{bmeta};
              main::write_file($p, watch::json::encode($st) . "\n");
          } },
        { call => 'append', rows => [ T::continue_row(600), T::assistant_text(601),
                                      T::boundary(700, uuid => 'b-idle', trigger => 'auto'), $notice->(700.2), T::summary(700.3) ] },
        { call => 'stop', at => 750 },
        { call => 'append', rows => [ T::continue_row(800), T::assistant_text(801),
                                      T::boundary(900, uuid => 'b-obs', trigger => 'auto'), T::summary(900.1),
                                      T::continue_row(1000), T::assistant_text(1001),
                                      map({ ($submit->(1010 + 10 * $_, $submits[$_]), T::assistant_text(1015 + 10 * $_)) } 0 .. $#submits) ] },
        { call => 'stop', at => 1100 },
        { call => 'append', rows => [ T::boundary(1200, uuid => 'b-modidle', trigger => 'auto'), T::summary(1200.1) ] },
        { call => 'stop', at => 1250 },
        { call => 'append', rows => [ T::continue_row(1300), T::assistant_text(1301) ] },
        { call => 'stop', at => 1400 },
    ],
    expect => sub {
        my ($E) = @_;
        my %b = map { ($_->{uuid} => $_) } $E->boundaries;
        $E->is(($b{'b-idle'} || {})->{idle_notice}, 'notice', 'the sweep marks the boundary the idle notice follows');
        $E->is(($b{'b-hist'} || {})->{idle_notice}, undef, 'and no other');
        $E->is($got{bmeta}, 1, 'the first Stop kept what it learned of the history boundary (then dropped, as by a 0.1.3 Stop)');
        $E->is(scalar(@submits), 3, 'the three handoff-turn submit lines of the plugin');
        my @a = $E->alerts('A-27');
        $E->count(\@a, 1, 'one A-27: the continue after the observed boundary (not the one after the history boundary, the mod\'s idle compaction or a handoff-turn submit)');
        $E->is(@a ? $a[0]{evidence}{line} : undef, 14, 'the last continue (transcript line 14)');
    },
};

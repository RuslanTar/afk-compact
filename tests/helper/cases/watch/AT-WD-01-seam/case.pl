# AT-WD-01-seam (CR-F15; small-rulings §4.1 item 1, REVIEW B-22, WATCHER-SPEC §8 item 6):
# core hands the watcher `settings::resolve`'s nested shape {values => {...}, source, notes},
# and `status` lets the watcher resolve it itself. Values from the user's settings file
# reach the watcher through both: `watcher` is trimmed and case-folded there too, an
# unknown value gives the /status note and one `config_note` row, and the other keys the
# rules read (handoff_turn, max_auto_continues_per_hour, stall_min, triggers, log_dir)
# are the resolved ones, not the defaults. The flat shape (this driver's) still works.
require watch::ctx;
my %got;
# the user's settings file, with no CLAUDE_PLUGIN_OPTION_* env (the launcher reads it)
my $cfg = sub { return { json => { pluginConfigs => { "$T::BRAND\@$T::BRAND" => { options => $_[0] } } } } };
my $env = { CLAUDE_CONFIG_DIR => '$HOME/.claude', CLAUDE_PLUGIN_ROOT => '' };
my $pre = watch::json::encode({ session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work',
                                hook_event_name => 'PreCompact', trigger => 'auto', custom_instructions => undef });
my $nested = sub { my ($v) = @_; return { values => $v, source => { map { $_ => 'settings' } keys %$v }, notes => [] } };
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    steps => [
        # in process, the nested shape core passes from `hook <Event>`
        { call => 'hook', event => 'PreCompact', at => 2, payload => { session_id => 'cccc0001', trigger => 'auto', custom_instructions => undef },
          ctx => { sid => 'cccc0001', settings => $nested->({ watcher => 'OFF ' }) } },
        { call => 'hook', event => 'PreCompact', at => 3, payload => { session_id => 'cccc0002', trigger => 'auto', custom_instructions => undef },
          ctx => { sid => 'cccc0002', settings => $nested->({ watcher => 'Shadow2' }) } },
        { call => 'code', code => sub {
            my $v = shift;
            my $c = watch::ctx::init({ sid => 'cccc0003', plugin_root => $v->{PLUGIN}, root => $v->{ROOT}, now => $T::BASE,
                settings => $nested->({ watcher => 'Shadow2', handoff_turn => 'off', max_auto_continues_per_hour => 0,
                                        stall_min => 7, triggers => 0, log_dir => "$v->{TMP}/elsewhere" }) });
            $got{nested} = join('/', map { $c->{settings}{$_} } qw(watcher watcher_unknown handoff_turn max_auto_continues_per_hour stall_min triggers));
            $got{nested_watch} = $c->{watch} eq "$v->{TMP}/elsewhere" ? 1 : 0;
            my $t = watch::ctx::init({ sid => 'cccc0004', plugin_root => $v->{PLUGIN}, root => $v->{ROOT}, now => $T::BASE,
                settings => $nested->({ triggers => 1 }) });
            $got{triggers_on} = $t->{settings}{triggers};
            my $f = watch::ctx::init({ sid => 'cccc0005', plugin_root => $v->{PLUGIN}, root => $v->{ROOT}, now => $T::BASE,
                settings => { watcher => 'Shadow2', handoff_turn => 'off', max_auto_continues_per_hour => 0 } });
            $got{flat} = join('/', map { $f->{settings}{$_} } qw(watcher watcher_unknown handoff_turn max_auto_continues_per_hour));
        } },
        # through the real launcher, values from the user's settings file only
        { call => 'write', path => '$HOME/.claude/settings.json', json => $cfg->({ watcher => 'OFF' })->{json} },
        { call => 'cli', at => 6, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, env => $env, any_stdout => 1 },
        { call => 'cli', at => 7, argv => ['status', '--sid', '$SID'], env => $env, any_stdout => 1 },
        { call => 'write', path => '$HOME/.claude/settings.json', json => $cfg->({ watcher => 'Shadow2' })->{json} },
        { call => 'cli', at => 8, argv => ['status', '--sid', '$SID'], env => $env, any_stdout => 1 },
        { call => 'cli', at => 9, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, env => $env, any_stdout => 1 },
        { call => 'cli', at => 10, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1, env => $env, any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my $w = $E->var('WATCH');
        $E->count([ $E->rows("$w/cccc0001.classic.jsonl", 'precompact') ], 0, "nested 'OFF ': watcher off");
        $E->count([ $E->rows("$w/cccc0002.classic.jsonl", 'precompact') ], 1, "nested 'Shadow2': watcher on");
        $E->count([ $E->rows("$w/cccc0002.classic.jsonl", 'config_note') ], 1, "nested 'Shadow2': one config_note row");
        $E->is($got{nested}, 'shadow/1/off/0/7/false', 'nested: resolved values reach the watcher');
        $E->is($got{nested_watch}, 1, 'nested: log_dir reaches the watcher');
        $E->is($got{triggers_on}, 'true', 'nested: triggers 1 is on');
        $E->is($got{flat}, 'shadow/1/off/0', 'flat shape still read');
        my @o = $E->outputs;
        my ($off_status, $unk_status) = map { $_->{stdout} // '' } @o[1, 2];
        $E->ok(($off_status =~ /^Watcher: off$/m ? 1 : 0), "settings file 'OFF': status says Watcher: off");
        $E->ok(($off_status =~ /^Watcher: shadow/m ? 0 : 1), "settings file 'OFF': status does not say shadow");
        $E->ok(($unk_status =~ /watcher setting is not "shadow" or "off"; it counts as shadow/ ? 1 : 0), "settings file 'Shadow2': status notes it");
        my @pre = $E->rows('classic', 'precompact');
        $E->count(\@pre, 2, "settings file: 'OFF' writes no precompact row, 'Shadow2' writes one per hook");
        $E->count([ $E->rows('classic', 'config_note') ], 1, "settings file 'Shadow2': one config_note row per session");
    },
};

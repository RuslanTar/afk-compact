# AT-P5-08 (P5-FOLD A3; BUILD-ROUND-9 WCH-02): with no mod `config_effective` row, the
# watcher's fallback thresholds equal the mod's clamp() (config.ts, plus the A3 window
# floor) for every window x `handoff_turn`. The table below is config.ts's arithmetic
# (reserve 52,000 + 64,000 with `halt`, 100,000 with `off`; native = window - 33,000;
# soft = min(600,000, native - reserve, floor(0.8 window)); target = min(400,000,
# floor(2 soft / 3)); off below 120,000). min_window: 329,000 (`halt`), 313,000 (`off`).
# The constants come from the spec's `clamp` object when it has them (one shared source).
my @T = (
['halt', 100000, 67000, -49000, -32667, 1],
['halt', 200000, 167000, 51000, 34000, 1],
['halt', 312999, 279999, 163999, 109332, 1],
['halt', 313000, 280000, 164000, 109333, 1],
['halt', 328999, 295999, 179999, 119999, 1],
['halt', 329000, 296000, 180000, 120000, 0],
['halt', 350000, 317000, 201000, 134000, 0],
['halt', 700000, 667000, 551000, 367333, 0],
['halt', 800000, 767000, 600000, 400000, 0],
['halt', 1000000, 967000, 600000, 400000, 0],
['off' , 100000, 67000, -33000, -22000, 1],
['off' , 200000, 167000, 67000, 44666, 1],
['off' , 312999, 279999, 179999, 119999, 1],
['off' , 313000, 280000, 180000, 120000, 0],
['off' , 328999, 295999, 195999, 130666, 0],
['off' , 329000, 296000, 196000, 130666, 0],
['off' , 350000, 317000, 217000, 144666, 0],
['off' , 700000, 667000, 560000, 373333, 0],
['off' , 800000, 767000, 600000, 400000, 0],
['off' , 1000000, 967000, 600000, 400000, 0],
);
{
    steps => [],
    expect => sub {
        my ($E) = @_;
        require watch::rules;
        my $th = sub {
            my ($settings, $spec) = @_;
            my $ctx = watch::ctx::init({ sid => $T::SID, settings => $settings, spec => ($spec || {}),
                                         plugin_root => $E->var('PLUGIN'), now => $T::BASE });
            return watch::rules::thresholds($ctx, { by => {} });
        };
        for my $r (@T) {
            my ($ht, $w, $native, $soft, $target, $off) = @$r;
            my $t = $th->({ handoff_turn => $ht, native_window_tokens => $w });
            my $id = "$ht/$w";
            $E->ok((ref $t eq 'HASH' ? 1 : 0), "$id: thresholds") or next;
            $E->is($t->{min_window}, ($ht eq 'halt' ? 329000 : 313000), "$id: min_window");
            if ($off) {
                $E->ok(($t->{off} ? 1 : 0), "$id: plugin compactions off");
                $E->is($t->{why}, 'trigger-disabled-small-window', "$id: why");
                $E->is($t->{soft_max_raw}, $soft, "$id: soft_max_raw");
                $E->is($t->{target_raw}, $target, "$id: target_raw");
                $E->ok((!defined $t->{target} ? 1 : 0), "$id: no target when off");
            } else {
                $E->ok(($t->{off} ? 0 : 1), "$id: on");
                $E->is($t->{native}, $native, "$id: native");
                $E->is($t->{soft_max}, $soft, "$id: soft_max");
                $E->is($t->{target}, $target, "$id: target");
            }
        }
        # Below the floor counts as the floor (Claude Code reads it as 100,000).
        my $f = $th->({ native_window_tokens => 50000 });
        $E->is($f->{window}, 100000, 'window 50,000 counts as 100,000');
        $E->is($f->{soft_max_raw}, -49000, 'floor: raw soft_max as at 100,000');
        # Settings parsed as the mod parses them: ` Off ` folds to off; an unknown value is halt.
        $E->is($th->({ handoff_turn => ' Off ', native_window_tokens => 313000 })->{target}, 120000, "' Off ' folds to off");
        $E->ok(($th->({ handoff_turn => 'sometimes', native_window_tokens => 313000 })->{off} ? 1 : 0), "'sometimes' counts as halt");
        # handoff_turn_max_tokens moves the reserve (clamped to 20,000..150,000 as the mod does).
        $E->is($th->({ handoff_turn_max_tokens => 150000, native_window_tokens => 1000000 })->{min_window}, 415000,
               'reserve 52,000 + 150,000: min_window 415,000');
        $E->is($th->({ handoff_turn_max_tokens => 900000, native_window_tokens => 1000000 })->{min_window}, 415000,
               'handoff_turn_max_tokens clamped to 150,000');
        $E->is($th->({ compact_target_tokens => 100000, native_window_tokens => 1000000 })->{min_window}, 'never',
               'target 100,000: min_window never');
        $E->ok(($th->({ triggers => 'false', native_window_tokens => 1000000 })->{off} ? 1 : 0), 'triggers false: off');
        $E->ok((!defined $th->({}) ? 1 : 0), 'window unknown (0): no fallback thresholds');
        # The shared constants: a spec `clamp` object changes the result.
        my $s = $th->({ native_window_tokens => 1000000 }, { clamp => { native_offset => 40000, reserve_base => 60000 } });
        $E->is($s->{native}, 960000, 'spec clamp.native_offset 40,000 is read');
        $E->is($s->{min_window}, 344000, 'spec clamp.reserve_base 60,000 is read (180,000 + 40,000 + 124,000)');
        my $b = $th->({ native_window_tokens => 1000000 }, { clamp => { native_offset => 'x', min_target => -1 } });
        $E->is($b->{native}, 967000, 'a non-numeric constant takes the built-in value');
    },
};

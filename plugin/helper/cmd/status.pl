# cmd/status.pl: `status --sid S` (MOD-SPEC §11; BUILD-PLAN §3.1). Owner: WP-core
# (+ watch.status_lines). Lines: effective thresholds (clamped marked), last 5
# compactions (seat_state, trigger, verdict, copy path), open escalations, halt
# state and continues this hour, smokeDue with the user-run smoke line, policy
# flags, unsafe roots, then the watcher's open alerts. Never content.
use strict;
use warnings;

package cmd_status;

our @ESCALATIONS = qw(copy_failed copy_mismatch copy_late verdict_mismatch root_in_git precompact_marker_orphan
                      sessionstart_ambiguous scope_leak layers_missing bypass_suspected mod_off resume_undelivered
                      halt thrash self_call_hook_ran keyset_change order_anomaly trigger_unknown version_change
                      version_hint compaction_unresolved lock_stale watch_error lane_unknown config_ambiguous);

sub _last {
    my ($rows, $ev) = @_;
    for my $r (reverse @$rows) { return $r if ($r->{ev} // '') eq $ev }
    return undef;
}

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid root log-dir)]);
    my $sid = args::init_sid($opt);
    my $d = rc::sid_dir();
    my @out;
    my $brand = ctx::brand();
    if (!defined $d) {
        args::out('status: no log folder (' . (rc::root_reason('log_dir') // 'unset') . ')');
        return 0;
    }
    my $mod = rollup::stream_rows(rc::stream_path('mod'));
    my $classic = rollup::stream_rows(rc::stream_path('classic'));
    my @all = (@$mod, @$classic);

    # thresholds
    my $eff = _last($mod, 'config_effective');
    if ($eff) {
        my %cl;
        for my $r (grep { ($_->{ev} // '') eq 'config_clamped' } @$mod) { $cl{ $r->{key} } = $r->{configured} if defined $r->{key} }
        my @parts;
        for my $k (qw(target soft_max window native_trigger)) {
            next unless defined $eff->{$k};
            my $v = $eff->{$k};
            $v .= " (clamped from $cl{$k})" if exists $cl{$k};
            push @parts, "$k $v";
        }
        my $state = $eff->{disabled} ? " · plugin compactions off ($eff->{disabled})" : '';
        push @out, 'thresholds: ' . join(' · ', @parts) . $state;
    } else {
        push @out, sprintf('thresholds: no mod row yet (settings: target %s · soft max %s)',
                           rc::val('compact_target_tokens'), rc::val('compact_soft_max_tokens'));
    }
    push @out, 'triggers: off (triggers-off)' if grep { ($_->{ev} // '') eq 'triggers_off' } @$mod;

    # last 5 compactions
    my $rolls = rollup::rows($d);
    my @last = @$rolls > 5 ? @$rolls[-5 .. -1] : @$rolls;
    my $nonok = grep { defined $_->{verdict} && $_->{verdict} !~ /^ok(-trailer)?$/ } @last;
    push @out, sprintf('compactions: %d in this session; last %d (%d not ok):', scalar @$rolls, scalar @last, $nonok);
    for my $r (reverse @last) {
        push @out, sprintf('  %s · %s · %s · %s · %s · copy %s', $r->{ts} // '-', $r->{actor} // '-', $r->{seat_state} // '-',
                           $r->{trigger} // '-', $r->{verdict} // '-',
                           defined $r->{copy_path} ? util::abbrev(rc::root() . '/' . $r->{copy_path}) : ($r->{copy} // 'none'));
    }

    # escalations
    my %n;
    for my $r (@all) { my $e = $r->{ev} // ''; $n{$e}++ if grep { $_ eq $e } @ESCALATIONS }
    my @esc = map { "$_ $n{$_}" } grep { $n{$_} } @ESCALATIONS;
    push @out, 'escalations: ' . (@esc ? join(', ', @esc) : 'none');

    # halt and continues
    my $hraw = util::read_file("$d/halt.json");
    my $h = defined $hraw ? eval { jsonc::decode($hraw) } : undef;
    my $now = util::now();
    my $cont = grep { ($_->{ev} // '') eq 'continue' && ($_->{result} // '') eq 'submitted'
                      && $now - (util::parse_iso($_->{ts} // '') // 0) <= 3600 } @$mod;
    push @out, sprintf('halt: %s · continues this hour: %d of %s',
                       (ref $h eq 'HASH' && $h->{halted} ? 'on (' . ($h->{reason} // 'unknown') . ')' : 'off'),
                       $cont, rc::val('max_auto_continues_per_hour'));

    # version / smoke
    my $vraw = util::read_file(rc::watch() . '/version.json');
    my $v = defined $vraw ? eval { jsonc::decode($vraw) } : undef;
    if (ref $v eq 'HASH' && defined $v->{smokeDue} && $v->{smokeDue} ne '') {
        push @out, "smokeDue: $v->{smokeDue} (Claude Code changed; run: ! " . ctx::store_cmd() . " smoke)";
        push @out, '  the instruction text\'s "next window has / lacks" list was last reviewed for '
                   . ($v->{previousVersion} // 'the previous version') . '; live smoke subset to re-run: AT-M1-13, AT-M2-05, AT-M4-05';
    } else {
        push @out, 'smokeDue: none' . (ref $v eq 'HASH' && $v->{lastVersion} ? " (Claude Code $v->{lastVersion})" : '');
    }

    # policy
    my $pol = _last($mod, 'policy');
    push @out, $pol ? sprintf('policy: mods managed only %s · hooks managed only %s',
                              ($pol->{mods_managed_only} ? 'yes' : 'no'), ($pol->{hooks_managed_only} ? 'yes' : 'no'))
                    : 'policy: no mod row yet';

    # unsafe roots
    for my $key (qw(handoff_root log_dir disposable_root)) {
        push @out, "root: $key refused (" . rc::root_reason($key) . '); copies and evidence under it are not written'
            unless rc::root_ok($key);
    }
    my $last_row = (sort map { $_->{ts} // '' } @$classic)[-1];
    push @out, 'last hook row: ' . ($last_row // 'none');

    # watcher lines (WP-watch)
    # The seam returns [line] (lib/watch.pm); a plain list is taken too.
    my @wl = eval { require "watch.pm"; watch::status_lines($sid) };
    @wl = map { ref $_ eq 'ARRAY' ? @$_ : $_ } @wl;
    push @out, grep { defined && !ref } @wl;
    args::out(@out);
    return 0;
}

exit(args::main(\&run, @ARGV));

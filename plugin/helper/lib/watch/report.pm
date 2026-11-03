package watch::report;
# lib/watch/report.pm: W13 `watch report` and `watch audit` (WATCHER-SPEC §10.2, §10.3, §10.7;
# W-BETA E; BUILD-PLAN §0 W13). Owner: WP-watch.
#
# Input: the live <watch> folder (every session's mod, classic, alerts and rollup rows and its
# events/ files), or with --input DIR a folder of export-transformed rows (a `report` bundle's
# rows/, one file per session), read by the same code. Rows only: the transcript-derived tier
# (D-01..D-06, M-18 after-side, the baseline from `watch backfill`) is not built in v1, so
# those lines say `deferred (derived tier)`, and with --input `n/a (remote)` (the owner has no
# friend transcript); neither counts as a failure. Output is counts, enums and ids only.
# `--export` puts the rows through the report export transform first (hashed ids, no paths).
use strict;
use warnings;
use utf8;
use POSIX ();
use watch::ctx;
use watch::io;
use watch::json;
use watch::export;
use watch::rules;

use watch::spec;

my %SHAPED = map { $_ => 1 } qw(mod-hook mod-self classic);

# --- loading ----------------------------------------------------------------

# load(ctx, input => DIR|undef, since => epoch|undef, export => X|undef)
#   -> {source => live|remote, sessions => {name => [rows sorted by ts]}}
sub load {
    my ($ctx, %o) = @_;
    my %S;
    if (defined $o{input}) {
        my $dir = $o{input};
        $dir = "$dir/rows" if -d "$dir/rows" && !grep { /\.jsonl\z/ } watch::io::list_dir($dir);
        for my $f (watch::io::list_dir($dir)) {
            next unless $f =~ /\A([0-9A-Za-z][0-9A-Za-z._-]{0,79})\.jsonl\z/ && -f "$dir/$f" && !-l "$dir/$f";
            my $bad = 0;
            $S{$1} = watch::io::read_jsonl("$dir/$f", \$bad);
        }
    } else {
        my $ss = -d $ctx->{watch} ? watch::export::sessions($ctx->{watch}) : {};
        for my $sid (keys %$ss) { $S{$sid} = watch::export::_rows_of_session($ss->{$sid}) }
    }
    for my $k (keys %S) {
        my @r;
        for my $r (@{ $S{$k} }) {
            next unless ref $r eq 'HASH';
            my $t = watch::io::parse_iso(ref $r->{ts} ? undef : $r->{ts});
            next if defined $o{since} && (!defined $t || $t < $o{since});
            if ($o{export}) { $r = watch::export::transform_row($r, $o{export}) or next }
            $r->{_t} = $t;
            push @r, $r;
        }
        my $name = $o{export} ? $o{export}{hash}->($k) : $k;
        $S{$name} = [ sort { ($a->{_t} // 0) <=> ($b->{_t} // 0) } @r ];
        delete $S{$k} if $name ne $k;
    }
    return { source => (defined $o{input} ? 'remote' : 'live'), sessions => \%S, spec => $ctx->{spec} };
}

sub _ev { return $_[0]{ev} // 'compaction' }
sub _b { my $v = shift; return ref $v eq 'SCALAR' ? ($$v ? 1 : 0) : ($v ? 1 : 0) }
# An idle value as the word M-01 uses: core writes a JSON bool (decoded 1 or 0) once
# reconcile settled it, `unknown` before; older rows hold the words.
sub _idle_word {
    my ($v) = @_;
    $v = $$v if ref $v eq 'SCALAR';
    return undef if !defined $v || ref $v;
    return $v eq '1' ? 'true' : $v eq '0' ? 'false' : $v;
}

# The compactions of one session: the sweep's boundary records (deduped by uuid; they carry
# the realtime fields M-01..M-20), else the rollup rows, each joined by nonce to core's
# `compaction_boundary` row (PKG-RUNTIME E.2; the first one per nonce counts): a null rollup
# size takes the boundary value, a non-null one is kept. In list context also the number of
# rollup rows whose non-null value disagrees with the boundary row (`join_conflict`).
sub compactions {
    my ($rows) = @_;
    my (%seen, @c, %bound);
    for my $r (grep { _ev($_) eq 'compaction_boundary' } @$rows) {
        $bound{ $r->{nonce} } //= $r if defined $r->{nonce} && !ref $r->{nonce};
    }
    my @roll = map { (defined $_->{nonce} && !ref $_->{nonce} && $bound{ $_->{nonce} })
                     ? watch::rules::join_row($_, $bound{ $_->{nonce} }) : $_ } grep { _ev($_) eq 'compaction' } @$rows;
    my $jc = grep { $_->{_join_conflict} } @roll;
    for my $r (grep { _ev($_) eq 'sweep' } @$rows) {
        for my $b (@{ ref $r->{boundaries} eq 'ARRAY' ? $r->{boundaries} : [] }) {
            next unless ref $b eq 'HASH';
            my $id = $b->{uuid} // join('|', $r->{file} // '', $b->{line} // '');
            next if $seen{$id}++;
            push @c, { src => 'sweep', main => (($b->{attributed} // '') eq 'main' ? 1 : 0), trigger => $b->{trigger},
                       pre => $b->{pre}, post => $b->{post}, duration_ms => $b->{duration_ms},
                       precomputed => _b($b->{precomputed}), verdict => $b->{verdict}, channel => $b->{channel},
                       copy => $b->{copy}, band => $b->{band_position}, nonce => $b->{nonce}, ts => $b->{ts},
                       warm_gap_s => $b->{warm_gap_s}, nudge_driven => _b($b->{nudge_driven}),
                       rapid => $b->{rapid_refill_run}, line => $b->{line}, idle => _idle_word($b->{idle}) };
        }
    }
    return wantarray ? (\@c, $jc) : \@c if @c;
    for my $r (@roll) {
        push @c, { src => 'rollup', main => (($r->{actor} // '') eq 'main' ? 1 : 0), trigger => $r->{trigger},
                   pre => $r->{pre_tokens}, post => $r->{post_tokens}, duration_ms => $r->{duration_ms},
                   precomputed => _b($r->{precomputed}), verdict => $r->{verdict}, channel => $r->{channel},
                   copy => $r->{copy}, band => undef, nonce => $r->{nonce}, ts => $r->{ts}, nudge_driven => _b($r->{nudged}),
                   idle => _idle_word($r->{idle}) };
    }
    return wantarray ? (\@c, $jc) : \@c;
}

# --- numbers ----------------------------------------------------------------

sub _pct {
    my ($sorted, $p) = @_;
    return undef unless @$sorted;
    my $i = int(($p / 100) * (@$sorted - 1) + 0.5);
    return $sorted->[$i];
}

sub stats {
    my ($L) = @_;
    my $okv = watch::spec::ok_verdicts($L->{spec});
    my %s = (sessions => 0, days => {}, alerts => {}, alert_rows => [], verdicts => {}, triggers => {},
             durations => {}, bands => [], chains => 0, nudge_driven => 0, receipts => 0, receipts_unselected => 0,
             lost_U => 0, lost_DX => 0, chain_steps => 0, fabricated => 0, summary => [], over12k => 0,
             resume_once => 0, resume_bad => 0, main => 0, save_gap => 0, shaped => 0, shaped_ok => 0, scope_leak => 0,
             cont_submitted => 0, cont_halt => 0, deny => undef, tool_calls => 0, publishes => 0, lint => {},
             heal_sha => 0, watch_errors => {}, sweep_partial => 0, cold_large => 0, warm_large => 0, cc => {},
             plugin_versions => {}, config => undef, rows => 0, join_conflict => 0);
    my @denied;
    for my $sid (sort keys %{ $L->{sessions} }) {
        my $rows = $L->{sessions}{$sid};
        next unless @$rows;
        $s{sessions}++;
        $s{rows} += @$rows;
        my ($C, $jc) = compactions($rows);
        $s{join_conflict} += $jc;
        my @main = grep { $_->{main} && !$_->{precomputed} } @$C;
        $s{main} += @main;
        $s{chains}++ if @main >= 3;
        $s{chain_steps} += @main > 1 ? @main - 1 : 0;
        # 0.1.3: an alert closed by a later `alert_closed` row (lib/watch/alerts.pm) is not counted
        my %closed = map { ($_->{alert_id} // '') => 1 } grep { _ev($_) eq 'alert_closed' } @$rows;
        my %inject;
        for my $r (@$rows) {
            my $ev = _ev($r);
            $s{cc}{ $r->{cc_version} }++ if defined $r->{cc_version} && !ref $r->{cc_version};
            $s{plugin_versions}{ $r->{plugin_version} }++ if defined $r->{plugin_version} && !ref $r->{plugin_version};
            if ($ev eq 'alert') {
                next if $closed{ $r->{alert_id} // '' };
                $s{alerts}{ $r->{rule} // '?' }++;
                push @{ $s{alert_rows} }, $r;
                $s{days}{ substr($r->{ts} // '????-??-??', 0, 10) }{alerts}++;
            } elsif ($ev eq 'postcompact') {
                my $l = ref $r->{ledger} eq 'HASH' ? $r->{ledger} : {};
                $s{lost_U} += $l->{lost_U} // 0;
                $s{lost_DX} += ($l->{lost_D} // 0) + ($l->{lost_X} // 0);
                $s{fabricated} += $r->{fabricated_check_tokens} // 0;
                if (($r->{form} // 'main') eq 'main' && defined $r->{summary_chars}) {
                    push @{ $s{summary} }, $r->{summary_chars};
                    $s{over12k}++ if $r->{summary_chars} > 12000;
                }
            } elsif ($ev eq 'resume_inject') {
                $inject{ $r->{nonce} // '' }++;
            } elsif ($ev eq 'resume_receipt') {
                $s{receipts}++;
                $s{receipts_unselected}++ if ($r->{relation} // '') eq 'unselected';
            } elsif ($ev eq 'continue') {
                my $res = $r->{result} // '';
                $s{cont_submitted}++ if $res eq 'submitted';
                $s{cont_halt}++ if $res =~ /\Ahalt:/;
            } elsif ($ev eq 'permission_denied') {
                push @denied, $r;
            } elsif ($ev eq 'sweep') {
                $s{tool_calls} += $r->{turns}{tool_calls} // 0 if ref $r->{turns} eq 'HASH';
            } elsif ($ev eq 'handoff_publish') {
                $s{publishes}++;
                $s{lint}{$_}++ for @{ ref $r->{lint_rules} eq 'ARRAY' ? $r->{lint_rules} : [] };
            } elsif ($ev eq 'heal') {
                $s{heal_sha}++ if ($r->{result} // '') =~ /\AREFUSED:sha/;
            } elsif ($ev eq 'watch_error') {
                $s{watch_errors}{ $r->{error_class} // '(none)' }++;
            } elsif ($ev eq 'sweep_partial') {
                $s{sweep_partial}++;
            } elsif ($ev eq 'config_effective') {
                $s{config} = $r;
            }
        }
        for my $c (@main) {
            $s{verdicts}{ $c->{verdict} // 'none' }++;
            $s{triggers}{ $c->{trigger} // 'unknown' }++;
            push @{ $s{durations}{ $c->{trigger} // 'unknown' } }, $c->{duration_ms} if defined $c->{duration_ms};
            push @{ $s{bands} }, $c->{pre} if defined $c->{pre};
            $s{nudge_driven}++ if $c->{nudge_driven};
            $s{idle}++ if ($c->{idle} // '') eq 'true';
            $s{save_gap}++ if !defined $c->{copy} || $c->{copy} =~ /\A(?:missing|not-found|failed)/;
            if ($SHAPED{ $c->{channel} // '' }) { $s{shaped}++; $s{shaped_ok}++ if $okv->{ $c->{verdict} // q() } }
            $s{scope_leak}++ if ($c->{verdict} // '') eq 'scope-leak';
            $s{days}{ substr($c->{ts} // '????-??-??', 0, 10) }{compactions}++;
            if (defined $c->{nonce} && $c->{nonce} ne 'none' && $c->{nonce} =~ /\A[0-9a-f]{8}\z/) {
                (($inject{ $c->{nonce} } // 0) == 1) ? $s{resume_once}++ : $s{resume_bad}++;
            }
            if (($c->{pre} // 0) >= 400000 && defined $c->{warm_gap_s}) {
                $c->{warm_gap_s} > 300 ? $s{cold_large}++ : $s{warm_large}++;
            }
        }
        $s{scope_leak} += 0;
    }
    $s{alerts_n} = scalar @{ $s{alert_rows} };
    $s{deny} = watch::rules::deny_counts(\@denied);
    return \%s;
}

# --- bars (§10.3) -------------------------------------------------------------

sub bars {
    my ($s, $source) = @_;
    my $tier = $source eq 'remote' ? 'n/a (remote)' : 'deferred (derived tier)';
    my @b;
    my $add = sub { push @b, [@_] };
    my $sample_ok = $s->{main} >= 20 && $s->{sessions} >= 3 && $s->{chains} >= 1 && $s->{nudge_driven} >= 3 && $s->{receipts} >= 3;
    $add->('Sample', '>=20 main compactions, >=3 sessions, a chain of >=3, >=3 nudge-driven, >=3 manual resumes',
           sprintf('%d main, %d sessions, %d chains, %d nudge-driven, %d resumes', @$s{qw(main sessions chains nudge_driven receipts)}),
           $sample_ok ? 'PASS' : 'FAIL (extend by 7 days)');
    $add->('Save gap', '0', $s->{save_gap}, $s->{save_gap} ? 'FAIL' : 'PASS');
    my $okp = $s->{shaped} ? 100 * $s->{shaped_ok} / $s->{shaped} : undef;
    $add->('Verdict ok/ok-trailer/ok-unclosed, shaped main', '>=90%', defined $okp ? sprintf('%.0f%% of %d', $okp, $s->{shaped}) : 'none',
           !defined $okp ? 'n/a (no shaped compaction)' : $okp >= 90 ? 'PASS' : 'FAIL');
    $add->('Scope leak', '0', $s->{scope_leak}, $s->{scope_leak} ? 'FAIL' : 'PASS');
    $add->('double_channel', '0', '-', 'n/a (not logged in v1)');
    my $ldx_ok = $s->{chain_steps} ? ($s->{lost_DX} / $s->{chain_steps}) <= 1 / 20 : $s->{lost_DX} == 0;
    $add->('lost_U; lost_D + lost_X', '0; <=1 per 20 chain steps', "$s->{lost_U}; $s->{lost_DX} in $s->{chain_steps} steps",
           ($s->{lost_U} == 0 && $ldx_ok) ? 'PASS' : 'FAIL');
    my $tcf = ($s->{alerts}{'A-07'} // 0) + ($s->{alerts}{'A-19'} // 0) + ($s->{alerts}{'A-17'} // 0);
    $add->('Thrash, cap breaches, unexplained failures', '0', "A-07 " . ($s->{alerts}{'A-07'} // 0) . ", A-19 "
           . ($s->{alerts}{'A-19'} // 0) . ", A-17 " . ($s->{alerts}{'A-17'} // 0), $tcf ? 'FAIL' : 'PASS');
    $add->('Post-compaction calls_to_progress', 'median <=3, p90 <=6', '-', $tier);
    my @sz = sort { $a <=> $b } @{ $s->{summary} };
    my $med = _pct(\@sz, 50);
    my $o12 = @sz ? 100 * $s->{over12k} / @sz : undef;
    $add->('Summary size', 'median 6-10K; over-12K <=10%',
           @sz ? sprintf('median %d, over-12K %.0f%%', $med, $o12) : 'none',
           !@sz ? 'n/a (no main summary)' : ($med >= 6000 && $med <= 10000 && $o12 <= 10) ? 'PASS' : 'FAIL');
    $add->('Nudge -> compaction within 2 turns', '>=90%', '-', $tier);
    my $want = $s->{nudge_driven} - $s->{cont_halt};
    $want = 0 if $want < 0;
    $add->('Auto-continue per nudge-driven compaction', '1, except a logged halt',
           "$s->{cont_submitted} continues, $s->{nudge_driven} nudge-driven, $s->{cont_halt} halts",
           $s->{nudge_driven} ? ($s->{cont_submitted} == $want ? 'PASS' : 'FAIL') : 'n/a (no nudge-driven compaction)');
    $add->('bg survival, shell and agent', 'missing = 0', '-', $tier);
    my $out = $s->{alerts}{'A-12'} // 0;
    $add->('outward_unconsented', '0', $out, $out ? 'FAIL' : 'PASS');
    $add->('Fabricated check tokens', '0', $s->{fabricated}, $s->{fabricated} ? 'FAIL' : 'PASS');
    my $rn = $s->{resume_once} + $s->{resume_bad};
    $add->('Resume block delivered once per main compaction', '100%', $rn ? "$s->{resume_once} of $rn" : 'none',
           !$rn ? 'n/a (no main compaction with a nonce)' : $s->{resume_bad} ? 'FAIL' : 'PASS');
    my $ctl = $s->{deny}{control};
    $add->('Deny rate, classifier-unavailable (control)', 'within +-50% of baseline',
           $s->{tool_calls} ? sprintf('%.1f/1000 calls', 1000 * $ctl / $s->{tool_calls}) : "$ctl denials",
           $source eq 'remote' ? 'n/a (remote)' : 'n/a (no baseline: watch backfill is deferred)');
    $add->('Watcher overhead', 'Stop p95 <=2 s', '-', 'n/a (no timing rows in v1)');
    return \@b;
}

# --- friction (§5, the row-derivable ones) -------------------------------------

sub friction {
    my ($s, $source) = @_;
    my @f;
    push @f, "FR-01 Silent save miss: save gap $s->{save_gap}" if $s->{save_gap};
    push @f, "FR-02 Lost decisions or constraints: lost_U $s->{lost_U}, lost_D+X $s->{lost_DX}" if $s->{lost_U} || $s->{lost_DX};
    if (@{ $s->{summary} } && $s->{over12k} / @{ $s->{summary} } > 0.10) {
        push @f, sprintf('FR-03 Summary bloat: over-12K %.0f%%', 100 * $s->{over12k} / @{ $s->{summary} });
    }
    my $g = $s->{deny}{guard_class};
    if (%$g) {
        my $calls = $s->{tool_calls} || 0;
        push @f, 'FR-14 Guard friction: ' . join(', ', map { sprintf('%s %s', $_, $calls ? sprintf('%.1f/1000 calls', 1000 * $g->{$_} / $calls) : "$g->{$_} denials") }
                                               sort keys %$g);
    }
    if ($s->{receipts} && $s->{receipts_unselected} / $s->{receipts} > 0.20) {
        push @f, sprintf('FR-16 Locate failures on manual resume: %d of %d unselected', $s->{receipts_unselected}, $s->{receipts});
    }
    for my $r (sort keys %{ $s->{lint} }) {
        push @f, "FR-18 Lint pressure: $r in $s->{lint}{$r} of $s->{publishes} publishes"
            if $s->{publishes} && $s->{lint}{$r} / $s->{publishes} > 0.30;
    }
    push @f, "FR-19 Restart refusals: $s->{heal_sha} sha refusals" if $s->{heal_sha};
    push @f, "FR-21 Fabricated checks: $s->{fabricated} tokens" if $s->{fabricated};
    my $we = 0;
    $we += $_ for values %{ $s->{watch_errors} };
    push @f, "FR-22 Watcher overhead: $we watch_error rows, $s->{sweep_partial} sweep_partial" if $we || $s->{sweep_partial};
    my $na = $source eq 'remote' ? 'n/a (remote)' : 'deferred (derived tier)';
    push @f, "FR-05, FR-06, FR-07, FR-08, FR-11, FR-12, FR-13, FR-15, FR-20: $na";
    return \@f;
}

# --- audit (§10.2 step 1) ----------------------------------------------------

sub audit {
    my ($L) = @_;
    my @fail;
    my $n = 0;
    for my $sid (sort keys %{ $L->{sessions} }) {
        my $rows = $L->{sessions}{$sid};
        next unless @$rows;
        $n++;
        my $C = compactions($rows);
        my $bounds = scalar grep { $_->{src} eq 'sweep' && $_->{main} && !$_->{precomputed} } @$C;
        my $post = scalar grep { _ev($_) eq 'postcompact' && ($_->{form} // 'main') eq 'main' } @$rows;
        my $roll = scalar grep { _ev($_) eq 'compaction' && ($_->{actor} // '') eq 'main' && !_b($_->{precomputed}) } @$rows;
        my $label = substr($sid, 0, 12);
        if (grep { $_->{src} eq 'sweep' } @$C) {
            push @fail, "counts $label: boundaries $bounds, postcompact $post, rollup $roll"
                unless $bounds == $post && ($roll == 0 || $roll == $bounds);
        }
        my %done;
        for my $r (@$rows) {
            my $ev = _ev($r);
            $done{ $r->{nonce} } = 1 if defined $r->{nonce} && !ref $r->{nonce}
                && $ev =~ /\A(?:compacted|compact_rejected|compaction_unresolved|precompute_or_failed|skip|copy_failed)\z/;
        }
        for my $d (grep { _ev($_) eq 'dispatch' } @$rows) {
            next if ($d->{trigger} // '') eq 'precompute' || !defined $d->{nonce} || ref $d->{nonce};
            push @fail, "dispatch $label: nonce $d->{nonce} has no compacted row and no explained failure" unless $done{ $d->{nonce} };
        }
        for my $w (grep { _ev($_) eq 'watch_error' } @$rows) {
            push @fail, "watch_error $label: a row without a class" unless defined $w->{error_class} && length $w->{error_class};
        }
    }
    return (\@fail, $n);
}

# --- rendering ----------------------------------------------------------------

sub _hist {
    my ($vals, $cfg) = @_;
    return ('(no main compaction with a size)') unless @$vals;
    my $step = 50000;
    my %h;
    $h{ int($_ / $step) }++ for @$vals;
    my ($max) = sort { $b <=> $a } values %h;
    my @marks;
    for my $k (qw(target soft_max native_trigger)) {
        push @marks, [$k, $cfg->{$k}] if $cfg && defined $cfg->{$k} && !ref $cfg->{$k} && $cfg->{$k} =~ /\A[0-9]+\z/;
    }
    my @l;
    my ($lo) = sort { $a <=> $b } keys %h;
    my ($hi) = sort { $b <=> $a } keys %h;
    for my $m (@marks) { my $i = int($m->[1] / $step); $lo = $i if $i < $lo; $hi = $i if $i > $hi }
    for my $i ($lo .. $hi) {
        my $n = $h{$i} // 0;
        my $bar = '#' x (($max && $n) ? int(40 * $n / $max + 0.999) : 0);
        my $mark = join(' ', map { "<- $_->[0] $_->[1]" } grep { int($_->[1] / $step) == $i } @marks);
        push @l, sprintf('%4dK-%4dK | %-40s %3d %s', $i * $step / 1000, ($i + 1) * $step / 1000, $bar, $n, $mark);
    }
    push @l, '(thresholds unknown: no config_effective row)' unless @marks;
    return @l;
}

sub render {
    my ($L, $s, %o) = @_;
    my ($fails) = audit($L);
    my $source = $L->{source};
    my @o;
    push @o, '# Watch report', '';
    push @o, '- Source: ' . ($source eq 'remote' ? 'export rows (--input)' : 'this machine') . ($o{export} ? ', export variant (ids hashed)' : '');
    push @o, '- Window: ' . ($o{since_label} // 'all');
    push @o, '- Plugin versions: ' . (join(', ', sort keys %{ $s->{plugin_versions} }) || 'unknown');
    push @o, '- Claude Code versions: ' . (join(', ', sort keys %{ $s->{cc} }) || 'unknown');
    push @o, sprintf('- Sample: %d sessions, %d rows, %d main compactions, %d alerts', @$s{qw(sessions rows main alerts_n)});
    my @days = sort keys %{ $s->{days} };
    push @o, '- Days covered: ' . (@days ? scalar(@days) . " ($days[0]..$days[-1])" : '0'), '';
    push @o, '## Audit', '';
    push @o, @$fails ? (map { "- FAIL $_" } @$fails) : ('- PASS (boundaries = postcompact = rollup rows; every dispatch settled; every watch_error has a class)');
    push @o, '', '## Bars (WATCHER-SPEC §10.3)', '', '| Bar | Target | Measured | Result |', '|---|---|---|---|';
    push @o, map { "| $_->[0] | $_->[1] | $_->[2] | $_->[3] |" } @{ bars($s, $source) };
    push @o, '', '## Per day', '', '| Day | Main compactions | Alerts |', '|---|---|---|';
    push @o, map { "| $_ | " . ($s->{days}{$_}{compactions} // 0) . ' | ' . ($s->{days}{$_}{alerts} // 0) . ' |' } @days;
    push @o, '', '## tokens_before (main compactions, 50K bins, to scale)', '', '```', _hist($s->{bands}, $s->{config}), '```';
    push @o, '', '## Duration by trigger (ms)', '', '| Trigger | n | p50 | p90 |', '|---|---|---|---|';
    for my $t (sort keys %{ $s->{durations} }) {
        my @d = sort { $a <=> $b } @{ $s->{durations}{$t} };
        push @o, sprintf('| %s | %d | %s | %s |', $t, scalar @d, _pct(\@d, 50) // '-', _pct(\@d, 90) // '-');
    }
    push @o, '', '## Verdict mix (main)', '';
    push @o, (%{ $s->{verdicts} } ? join(', ', map { "$_ $s->{verdicts}{$_}" } sort keys %{ $s->{verdicts} }) : 'none');
    push @o, '', 'Idle compactions (the rollup `idle` field, IC-1): ' . ($s->{idle} // 0) . " of $s->{main}";
    push @o, '', "Size join conflicts (rollup vs compaction_boundary, the rollup value kept): $s->{join_conflict}";
    my $d = $s->{deny};
    my $cnt = sub { my $h = shift; return join(', ', map { "$_ $h->{$_}" } sort keys %$h) || 'none' };
    push @o, '', '## Denials (permission_denied rows, D-13)', '';
    push @o, "- Total: $d->{total}; control (reason classifier-unavailable, kept apart): $d->{control}",
             '- By turn kind: ' . $cnt->($d->{turn_kind}), '- By cause: ' . $cnt->($d->{caused_by}),
             "- In a post-compaction turn caused by the plugin: $d->{post_compaction_plugin}",
             '- By guard class (control excluded): ' . $cnt->($d->{guard_class});
    push @o, '', '## Background survival', '', ($source eq 'remote' ? 'n/a (remote)' : 'deferred (derived tier)');
    push @o, '', '## Friction (WATCHER-SPEC §5)', '', map { "- $_" } @{ friction($s, $source) };
    push @o, '', '## Alerts by rule', '';
    my %by;
    push @{ $by{ $_->{rule} // '?' } }, $_ for @{ $s->{alert_rows} };
    if (!%by) { push @o, 'none' }
    for my $rule (sort keys %by) {
        push @o, "### $rule (" . scalar(@{ $by{$rule} }) . ')';
        for my $a (@{ $by{$rule} }) {
            my $k = ref $a->{key} eq 'HASH' ? $a->{key} : {};
            my $ev = ref $a->{evidence} eq 'HASH' ? $a->{evidence} : {};
            push @o, sprintf('- %s %s session %s actor %s nonce %s%s', $a->{severity} // '?', $a->{alert_id} // '?',
                             substr($k->{session_id} // '?', 0, 12), $k->{actor} // '?', $k->{nonce} // '-',
                             defined $ev->{line} ? " line $ev->{line}" : '');
        }
    }
    push @o, '', '## Cost (estimated)', '';
    push @o, sprintf('Large compactions (>=400K): %d cold (est. about $4 each), %d warm (est. about $0.3 each); cold = warm gap over 300 s.',
                     $s->{cold_large}, $s->{warm_large});
    push @o, '', '## Baseline vs shadow', '', ($source eq 'remote' ? 'n/a (remote)' : 'n/a (no baseline: watch backfill is deferred)');
    push @o, '', '## Experimental (not bars)', '', '- deny rate control class, bg survival, calls_to_progress: see above', '';
    return join("\n", @o);
}

# --- the commands ---------------------------------------------------------------

sub _since_arg {
    my ($a, $now) = @_;
    return (undef, 'all') if !defined $a || $a eq 'all';
    my $t = watch::export::_since($a, $now);
    return ('bad') if defined $t && $t eq 'bad';
    return ($t, $a);
}

sub _opts {
    my ($argv, %allow) = @_;
    my %o;
    my @a = @$argv;
    while (@a) {
        my $x = shift @a;
        if ($x eq '--since') { $o{since} = shift @a; return unless defined $o{since} }
        elsif ($x =~ /\A--since=(.+)\z/) { $o{since} = $1 }
        elsif ($x eq '--input') { $o{input} = shift @a; return unless defined $o{input} && -d $o{input} }
        elsif ($x =~ /\A--input=(.+)\z/) { $o{input} = $1; return unless -d $o{input} }
        elsif ($allow{out} && $x eq '--out') { $o{out} = shift @a; return unless defined $o{out} && length $o{out} }
        elsif ($allow{export} && $x eq '--export') { $o{export} = 1 }
        else { return }
    }
    return \%o;
}

# report_cli(\@argv) -> exit code. Prints `WATCH-REPORT <path>`, or the report itself with
# --input and no --out. `REFUSED: <key>: <reason>`, exit 3, when it would write under a refused
# watch dir or handoff root (WATCH §6.1).
sub report_cli {
    my ($argv, $seed) = @_;
    my $o = _opts($argv, out => 1, export => 1) or return 64;
    my $ctx = watch::ctx::init({ %{ $seed || {} }, sid => 'unknown' });
    my ($since, $label) = _since_arg($o->{since}, $ctx->{now});
    return 64 if defined $since && $since eq 'bad';
    return 64 if $o->{export} && defined $o->{input};
    # WATCH §6.1: a report that writes under the watch dir (--export's salt, the default
    # reports/ folder) writes nothing there while the watch dir or handoff root is refused
    if ($o->{export} || (!defined $o->{out} && !defined $o->{input})) {
        if (my $why = watch::ctx::refused($ctx)) { print "REFUSED: $why\n"; return 3 }
    }
    my $X;
    if ($o->{export}) {
        my ($salt) = watch::export::keys_for($ctx->{watch}, 0);
        $X = { hash => watch::export::hasher($salt, $ctx->{sha256}), dropped => {},
               headings => watch::export::heading_ids($ctx->{spec}) };
    }
    my $L = load($ctx, input => $o->{input}, since => $since, export => $X);
    my $md = render($L, stats($L), since_label => $label, export => $o->{export});
    utf8::encode($md) if utf8::is_utf8($md);
    if ($o->{export}) {
        my $ids = watch::export::identity_list($ctx, no_git => (($ENV{STORE_TEST_MODE} // '') eq '1' && ($ENV{STORE_TEST_NO_GIT} // '') eq '1'));
        if (watch::export::identity_hits($md, $ids)) { print "REFUSED: identity in the export\n"; return 3 }
    }
    my $path = $o->{out};
    if (!defined $path && defined $o->{input}) { print $md; return 0 }
    unless (defined $path) {
        my $dir = "$ctx->{watch}/reports";
        watch::io::mkdir_p($dir) or do { print "REFUSED: output folder not writable\n"; return 73 };
        my $base = watch::io::local_date($ctx->{now}) . '_watch-report' . ($o->{export} ? '-export' : '');
        $path = "$dir/$base.md";
        my $i = 1;
        $path = "$dir/$base-" . ++$i . '.md' while -e $path;
    }
    return 73 unless watch::export::_write_new($path, $md);
    print "WATCH-REPORT $path\n";
    return 0;
}

sub audit_cli {
    my ($argv, $seed) = @_;
    my $o = _opts($argv) or return 64;
    my $ctx = watch::ctx::init({ %{ $seed || {} }, sid => 'unknown' });
    my ($since) = _since_arg($o->{since}, $ctx->{now});
    return 64 if defined $since && $since eq 'bad';
    my $L = load($ctx, input => $o->{input}, since => $since);
    my ($fails, $n) = audit($L);
    print "AUDIT FAIL $_\n" for @$fails;
    print @$fails ? 'AUDIT: FAIL (' . scalar(@$fails) . " problems, $n sessions)\n" : "AUDIT: PASS ($n sessions)\n";
    return @$fails ? 1 : 0;
}

1;

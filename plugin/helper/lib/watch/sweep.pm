package watch::sweep;
# lib/watch/sweep.pm: the incremental transcript sweeper (WATCHER-SPEC §1.1).
# Owner: WP-watch.
#
# Per transcript file one offset file `<watch>/<sid>/offsets/<basename>.off`
# holds {path, inode, size, offset, line, last_uuid, carry}, written in place
# under flock by the Stop hook (one writer per sid). `carry` is the analyzer
# state that spans Stops (content-free: ids, counts, line numbers, times).
# The main transcript's offset file also holds the session-level `session`
# state of the rule engine.
#
# A run reads at most 5 MB in total; whole lines only. A changed path or inode,
# or a file shorter than the offset, restarts that file at 0; rows up to the
# last processed uuid are skipped and boundaries are deduplicated by uuid.
# Reading stops at the soft time limit (`time_cut`); the 5 MB cap alone only
# marks the run `partial` (the rest is read at the next Stop, WATCH §1.1).
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::json;
use watch::rows;
use watch::spec;
use watch::hturn;

our $RUN_BYTES = 5 << 20;
our $MAX_LINE = 2 << 20;
my $SEEN_CAP = 500;

sub _basename { (my $b = $_[0]) =~ s{.*/}{}; return $b }

sub _off_path {
    my ($ctx, $file) = @_;
    return watch::ctx::sid_dir($ctx) . '/offsets/' . _basename($file) . '.off';
}

sub _load_state {
    my ($fh) = @_;
    my $raw = watch::io::read_handle($fh);
    my $s = length $raw ? eval { watch::json::decode($raw) } : undef;
    return ref $s eq 'HASH' ? $s : {};
}

sub _save_state {
    my ($fh, $state) = @_;
    return watch::io::rewrite_handle($fh, watch::json::encode($state) . "\n");
}

# Subagent transcripts live in `<transcript minus .jsonl>/subagents/agent-*.jsonl`.
sub subagent_files {
    my ($main) = @_;
    (my $dir = $main) =~ s/\.jsonl\z//;
    $dir .= '/subagents';
    return () unless -d $dir;
    return map { "$dir/$_" } grep { /\Aagent-[A-Za-z0-9_-]+\.jsonl\z/ } watch::io::list_dir($dir);
}

# Should subagent transcripts be swept? Only after a non-main dispatch.
sub want_subagents {
    my ($ctx) = @_;
    my $dir = watch::ctx::sid_dir($ctx) . '/dispatch';
    for my $f (watch::io::list_dir($dir)) {
        next unless $f =~ /\.json\z/;
        my $d = watch::io::read_json_file("$dir/$f");
        return 1 if ref $d eq 'HASH' && (defined $d->{agent_id} || ($d->{actor} // '') ne 'main');
    }
    return 0;
}

sub _new_carry { return { line => 0, prompts => 0, b_seq => 0, rapid_run => 0, seen_b => [] } }

# Scan one file. Returns a result hash; updates $state in place.
sub scan_file {
    my ($ctx, $path, $state, $budget, $soft, $actor, $is_main, $outward) = @_;
    my %res = (file => _basename($path), actor => $actor, events => [], boundaries => [],
               bad_lines => 0, oversize_lines => 0, partial => 0, restarted => 0, handoff_turn => [],
               turns => { prompts => 0, tool_batches => 0, tool_calls => 0, classes => {}, errors => {},
                          askq => { answered => 0, rejected => 0, timed_out => 0 }, plugin_origin_rows => 0, continues => 0, handoff_turns => 0, outward => {},
                          nudges => 0, task_status => 0 });
    my @st = stat $path;
    unless (@st && -r _) { $res{unreadable} = 1; return \%res }
    my ($ino, $size) = ($st[1], $st[7]);
    my $carry = ref $state->{carry} eq 'HASH' ? $state->{carry} : _new_carry();
    my $off = defined $state->{offset} ? $state->{offset} : 0;
    my $skip_until;
    if (!defined $state->{path} || $state->{path} ne $path || ($state->{inode} // -1) != $ino || $size < $off) {
        if (defined $state->{path}) {
            $res{restarted} = 1;
            my $last = $state->{last_uuid};
            $skip_until = $last if defined $last && _file_has($path, $last);
            my ($seen, $used) = ($carry->{seen_b}, $carry->{ht_used});
            $carry = _new_carry();
            $carry->{seen_b} = $seen if ref $seen eq 'ARRAY';
            $carry->{ht_used} = $used if ref $used eq 'HASH';
        }
        $off = 0;
        $carry->{line} = 0;
    }
    $res{from_off} = $off;
    my $stem = _basename($path);
    $stem =~ s/\.jsonl\z//;
    open(my $fh, '<:raw', $path) or do { $res{unreadable} = 1; return \%res };
    seek($fh, $off, 0);
    my $want = $size - $off;
    $want = $budget if $want > $budget;
    my $chunk = '';
    read($fh, $chunk, $want) if $want > 0;
    my $consumed = 0;
    my $n = 0;
    my $last_uuid = $state->{last_uuid};
    my $pos = 0;
    while ($pos < length $chunk) {
        # The time check comes before the next line is consumed, so every
        # consumed line has been analyzed.
        if ($n && $n % 200 == 0 && watch::io::mono() > $soft) { $res{partial} = 1; $res{time_cut} = 1; last }
        my $nl = index($chunk, "\n", $pos);
        if ($nl < 0) {
            if ($pos == 0 && length($chunk) == $budget && $budget > 0) {
                my $skip = _skip_to_newline($fh, $off + length $chunk);
                if (defined $skip) {
                    $consumed = $skip - $off;
                    $carry->{line}++;
                    $res{oversize_lines}++;
                }
            }
            last;
        }
        my $line = substr($chunk, $pos, $nl - $pos);
        $pos = $nl + 1;
        $consumed = $pos;
        $carry->{line}++;
        $n++;
        next unless $line =~ /\S/;
        if (defined $skip_until) {
            if (index($line, $skip_until) >= 0) {
                my $r = eval { watch::json::decode($line) };
                undef $skip_until if ref $r eq 'HASH' && defined $r->{uuid} && $r->{uuid} eq $skip_until;
            }
            next;
        }
        if (length($line) > $MAX_LINE) { $res{oversize_lines}++; next }
        my $r = eval { watch::json::decode($line) };
        unless (ref $r eq 'HASH') { $res{bad_lines}++; next }
        my $f = watch::rows::classify($r, $ctx->{brand}, $outward);
        $last_uuid = $f->{uuid} if defined $f->{uuid};
        _analyze($ctx, \%res, $carry, $f, $is_main, $stem);
    }
    close $fh;
    $res{to_off} = $off + $consumed;
    $res{bytes} = $consumed;
    $res{more} = ($off + $consumed < $size) ? 1 : 0;
    $res{partial} = 1 if $res{more};
    @{ $carry->{seen_b} } = @{ $carry->{seen_b} }[-$SEEN_CAP .. -1] if @{ $carry->{seen_b} } > $SEEN_CAP;
    %$state = (path => $path, inode => $ino, size => $size, offset => $off + $consumed,
               last_uuid => $last_uuid, carry => $carry, session => $state->{session});
    return \%res;
}

sub _file_has {
    my ($path, $needle) = @_;
    open(my $fh, '<:raw', $path) or return 0;
    my ($buf, $tail, $read) = ('', '', 0);
    while (my $n = read($fh, $buf, 1 << 20)) {
        my $s = $tail . $buf;
        if (index($s, $needle) >= 0) { close $fh; return 1 }
        $tail = substr($s, -length($needle));
        $read += $n;
        last if $read > (256 << 20);
    }
    close $fh;
    return 0;
}

sub _skip_to_newline {
    my ($fh, $at) = @_;
    seek($fh, $at, 0);
    my $buf;
    my $p = $at;
    while (my $n = read($fh, $buf, 1 << 20)) {
        my $i = index($buf, "\n");
        return $p + $i + 1 if $i >= 0;
        $p += $n;
    }
    return undef;
}

sub _ev { my ($res, %e) = @_; push @{ $res->{events} }, \%e; return \%e }

sub _analyze {
    my ($ctx, $res, $c, $f, $is_main, $stem) = @_;
    my $k = $f->{kind} // 'other';
    my $line = $c->{line};
    my $t = $res->{turns};

    if ($is_main && defined $f->{sid} && $f->{sid} ne $stem && $c->{cur_b} && !$c->{cur_b}{sid_bad}) {
        $c->{cur_b}{sid_bad} = 1;
        _ev($res, k => 'sid_mismatch', b_uuid => $c->{cur_b}{uuid}, line => $line);
        $_->{sid_canary} = \0 for grep { ($_->{uuid} // '') eq ($c->{cur_b}{uuid} // '') } @{ $res->{boundaries} };
    }

    if ($k eq 'boundary') {
        my $uuid = $f->{uuid};
        return if defined $uuid && grep { $_ eq $uuid } @{ $c->{seen_b} };
        push @{ $c->{seen_b} }, $uuid if defined $uuid;
        my $trig = $f->{trigger};
        my $detail;
        if ($f->{precomputed}) { $detail = 'precompute-installed' }
        elsif (defined $trig && $trig eq 'auto') {
            my $rel = $c->{last_rel} // '';
            my $stopped = defined $c->{last_stop_ts} && defined $c->{last_assistant_ts}
                          && $c->{last_stop_ts} >= $c->{last_assistant_ts};
            if ($rel eq 'prompt') { $detail = 'auto-turnstart' }
            elsif (($rel eq 'tool_result' || ($rel eq 'assistant' && !$c->{last_text_only})) && !$stopped) {
                $detail = 'auto-midturn';
            }
        }
        my $warm = (defined $f->{ts} && defined $c->{last_assistant_ts}) ? int($f->{ts} - $c->{last_assistant_ts} + 0.5) : undef;
        my ($turns, $refill);
        my $counted = $is_main && !$f->{precomputed};
        if ($counted && $c->{prev_b}) {
            $turns = $c->{prompts} - $c->{prev_b}{prompts_at};
            if ($turns > 0 && defined $f->{pre} && defined $c->{prev_b}{post}) {
                $refill = int(($f->{pre} - $c->{prev_b}{post}) / $turns);
            }
        }
        if ($counted) {
            $c->{rapid_run} = (defined $turns && $turns < 3) ? $c->{rapid_run} + 1 : 0;
        }
        $c->{b_seq}++;
        my %b = (
            line => $line, uuid => $uuid, ts => (defined $f->{ts} ? watch::io::iso($f->{ts}) : undef),
            ts_epoch => $f->{ts}, seq => $c->{b_seq}, trigger => $trig, boundary_trigger => $trig,
            trigger_detail => $detail,
            pre => $f->{pre}, post => $f->{post}, duration_ms => $f->{duration_ms},
            precomputed => watch::ctx::B($f->{precomputed}), dropped => $f->{dropped},
            preserved_segment => watch::ctx::B($f->{preserved_segment}), summary_line => undef,
            summary_flags => undef, version => $f->{version},
            sid_canary => ($is_main && defined $f->{sid} && $f->{sid} ne $stem) ? \0 : \1,
            warm_gap_s => $warm, turns_since_prev => $turns, refill_per_turn => $refill,
            rapid_refill_run => ($counted ? $c->{rapid_run} : undef),
            nudge_driven => watch::ctx::B($c->{nudge_since_b}),
            actor => $res->{actor}, file => $res->{file},
        );
        push @{ $res->{boundaries} }, \%b;
        _ev($res, k => 'boundary', b => \%b, line => $line, ts => $f->{ts});
        $c->{cur_b} = { uuid => $uuid, rows_left => 50, pending => 1 };
        $c->{nudge_since_b} = 0;
        if ($counted) {
            $c->{prev_b} = { prompts_at => $c->{prompts}, post => $f->{post}, uuid => $uuid };
            $c->{last_main_b} = { uuid => $uuid, nudged => ($b{nudge_driven} && ${ $b{nudge_driven} }) ? 1 : 0 };
        }
        $c->{win} = { kind => 'boundary', uuid => $uuid, line => $line, calls => 0, consent => 0 };
        $c->{prog} = { uuid => $uuid, batches => 0, done => 0 } if $is_main;
        $c->{last_nudge} = undef;
        return;
    }
    if ($c->{cur_b} && $c->{cur_b}{pending}) {
        if ($k eq 'summary') {
            for my $b (grep { ($_->{uuid} // '') eq ($c->{cur_b}{uuid} // '') } @{ $res->{boundaries} }) {
                $b->{summary_line} = $line;
                $b->{summary_flags} = { compact_summary => watch::ctx::B($f->{is_compact_summary}),
                                        visible_only => watch::ctx::B($f->{visible_only}) };
            }
            $c->{cur_b}{pending} = 0;
            return;
        }
        $c->{cur_b}{pending} = 0 if --$c->{cur_b}{rows_left} <= 0;
    }
    return unless $is_main;

    # M-17 (DP-14): the plugin-submitted handoff turn is a plugin-origin `user` row like a
    # continue; an open ht record (handoff-turn/<ht>.json, one submit per ht) makes it a
    # `handoff_turn`. It is a turn, not a continue: no continue event, no A-19/A-27 input.
    my $ht;
    if ($k eq 'continue') {
        $ht = watch::hturn::submit_for($ctx, $f->{ts}, $c->{ht_used} ||= {});
        if ($ht) {
            $c->{ht_used}{ $ht->{ht} } = 1;
            $k = 'handoff_turn';
        }
    }
    if ($k eq 'prompt' || $k eq 'continue' || $k eq 'handoff_turn' || $k eq 'plugin_prompt') {
        $c->{prompts}++;
        $t->{prompts}++;
        $c->{last_rel} = 'prompt';
        if ($c->{prog} && !$c->{prog}{done}) { $c->{prog}{done} = 1 }
        if ($k eq 'prompt') {
            if ($f->{resume_invocation}) {
                $c->{win} = { kind => 'resume', uuid => $f->{uuid}, line => $line, calls => 0, consent => 0,
                              args => $f->{resume_args} ? 1 : 0 };
                _ev($res, k => 'resume_invocation', line => $line, ts => $f->{ts}, uuid => $f->{uuid});
            } elsif ($c->{win}) {
                $c->{win}{consent} = 1;
            }
        } else {
            $t->{plugin_origin_rows}++;
            $t->{continues}++ if $k eq q(continue);
        }
        if ($k eq 'handoff_turn') {
            $t->{handoff_turns}++;
            push @{ $res->{handoff_turn} }, { ht => $ht->{ht}, line => $line };
            _ev($res, k => 'handoff_turn', line => $line, ts => $f->{ts}, uuid => $f->{uuid}, ht => $ht->{ht});
        }
        if ($k eq 'continue') {
            my $lb = $c->{last_main_b} || {};
            _ev($res, k => 'continue', line => $line, ts => $f->{ts}, uuid => $f->{uuid},
                b_uuid => $lb->{uuid}, b_nudged => $lb->{nudged} ? 1 : 0);
        }
        my $ln = $c->{last_nudge};
        if ($ln && !$ln->{done} && $c->{prompts} - $ln->{prompts_at} > 2 && $ln->{b_seq} == $c->{b_seq}) {
            $ln->{done} = 1;
            _ev($res, k => 'nudge_unresolved', line => $ln->{line}, ts => $f->{ts});
        }
        return;
    }
    if ($k eq 'nudge') {
        $t->{nudges}++;
        $c->{nudge_since_b} = 1;
        $c->{last_nudge} = { prompts_at => $c->{prompts}, b_seq => $c->{b_seq}, line => $line };
        _ev($res, k => 'nudge', line => $line, ts => $f->{ts});
        return;
    }
    if ($k eq 'assistant') {
        $c->{last_assistant_ts} = $f->{ts} if defined $f->{ts};
        $c->{last_rel} = 'assistant';
        $c->{last_text_only} = $f->{text_only} ? 1 : 0;
        my @calls = @{ $f->{calls} || [] };
        return unless @calls;
        $t->{tool_batches}++;
        my $progress = 0;
        for my $call (@calls) {
            $t->{tool_calls}++;
            $t->{classes}{ $call->{mcp} ? q(mcp) : $call->{name} }++;
            $t->{outward}{$_}++ for @{ $call->{outward} || [] };
            $c->{asks}{ $call->{id} } = 1 if $call->{ask} && defined $call->{id};
            $progress = 1 if $call->{progress} && !$call->{heal};
            if ($call->{heal}) {
                _ev($res, k => 'heal_call', line => $line, ts => $f->{ts}, name => $call->{name});
            }
            my $w = $c->{win};
            next unless $w && $w->{calls} < 10;
            $w->{calls}++;
            if (!$w->{consent}) {
                for my $cls (@{ $call->{outward} || [] }) {
                    _ev($res, k => 'outward', line => $line, ts => $f->{ts}, class => $cls, call_no => $w->{calls},
                        win_kind => $w->{kind}, win_uuid => $w->{uuid}, win_line => $w->{line},
                        args => $w->{args} ? 1 : 0);
                }
            }
            if ($w->{kind} eq 'boundary' && defined $call->{stop_id}) {
                _ev($res, k => 'taskstop', line => $line, ts => $f->{ts}, stop_id => $call->{stop_id},
                    win_uuid => $w->{uuid});
            }
        }
        my $p = $c->{prog};
        if ($p && !$p->{done}) {
            $p->{batches}++;
            if ($progress) { $p->{done} = 1 }
            elsif ($p->{batches} > 6 && !$p->{flagged}) {
                $p->{flagged} = 1;
                _ev($res, k => 'slow_progress', line => $line, ts => $f->{ts}, b_uuid => $p->{uuid}, batches => $p->{batches});
            }
        }
        return;
    }
    if ($k eq 'tool_result') {
        $c->{last_rel} = 'tool_result';
        for my $r (@{ $f->{results} || [] }) {
            $t->{errors}{tool}++ if $r->{is_error};
            if (defined $r->{id} && $c->{asks} && delete $c->{asks}{ $r->{id} }) {
                my $o = $r->{timed_out} ? 'timed_out' : $r->{is_error} ? 'rejected' : 'answered';
                $t->{askq}{$o}++;
            }
        }
        return;
    }
    if ($k eq 'api_error') {
        $t->{errors}{ 'api-' . $f->{error_class} }++;
        _ev($res, k => 'api_error', line => $line, ts => $f->{ts}, class => $f->{error_class});
        return;
    }
    if ($k eq 'task_status') {
        $t->{task_status}++;
        if (defined $f->{task_id} && !ref $f->{task_id}) {
            $c->{task_types}{ $f->{task_id} } = $f->{task_type} if defined $f->{task_type} && !ref $f->{task_type};
        }
        return;
    }
}

# Run the sweep over the main transcript (and subagent files when wanted).
# Returns {busy|unreadable, files => [results], state => main state, fh}.
sub run {
    my ($ctx, $soft) = @_;
    my $main = $ctx->{payload}{transcript_path};
    return { none => 1 } unless defined $main && !ref $main && length $main;
    my ($fh, $why) = watch::io::open_locked(_off_path($ctx, $main));
    return { busy => 1 } unless $fh;
    my $state = _load_state($fh);
    my $outward = watch::spec::classes($ctx->{spec}, 'outward_classes');
    my @files;
    my @subs;
    my $budget = $RUN_BYTES;
    my $r = scan_file($ctx, $main, $state, $budget, $soft, 'main', 1, $outward);
    push @files, $r;
    $budget -= $r->{bytes} || 0;
    if (!$r->{partial} && $budget > 0 && want_subagents($ctx)) {
        for my $sf (subagent_files($main)) {
            last if $budget <= 0 || watch::io::mono() > $soft;
            my ($sfh) = watch::io::open_locked(_off_path($ctx, $sf));
            next unless $sfh;
            my $ss = _load_state($sfh);
            (my $agent = _basename($sf)) =~ s/\Aagent-|\.jsonl\z//g;
            my $sr = scan_file($ctx, $sf, $ss, $budget, $soft, $agent, 0, $outward);
            # Saved in finish(), with the main offsets, so an abandoned run
            # keeps no progress for any file.
            push @subs, [$sfh, $ss];
            $budget -= $sr->{bytes} || 0;
            push @files, $sr;
        }
    }
    return { files => \@files, state => $state, fh => $fh, subs => \@subs };
}

sub finish {
    my ($run) = @_;
    return unless $run;
    for my $s (@{ delete $run->{subs} || [] }) {
        _save_state($s->[0], $s->[1]);
        close $s->[0];
    }
    return unless $run->{fh};
    _save_state($run->{fh}, $run->{state});
    close $run->{fh};
    delete $run->{fh};
}

# Drop a run without saving any offset: the next Stop reads the same bytes again.
sub abandon {
    my ($run) = @_;
    return unless $run;
    close $_->[0] for @{ delete $run->{subs} || [] };
    close $run->{fh} if $run->{fh};
    delete $run->{fh};
}

# `sweep` rows: one per file with new bytes; boundaries split so each row
# stays under the 4 KB row cap.
sub rows_for {
    my ($res) = @_;
    return () if !$res->{bytes} && !$res->{restarted} && !$res->{unreadable};
    my @b = map {
        my %x = %$_;
        delete @x{qw(ts_epoch actor file)};
        \%x
    } @{ $res->{boundaries} };
    my %base = (file => $res->{file}, actor => $res->{actor}, from_off => $res->{from_off},
                to_off => $res->{to_off}, partial => watch::ctx::B($res->{partial}),
                restarted => watch::ctx::B($res->{restarted}), bad_lines => $res->{bad_lines},
                oversize_lines => $res->{oversize_lines});
    $base{handoff_turn} = $res->{handoff_turn} if @{ $res->{handoff_turn} || [] };
    my @rows;
    my @cur;
    my $first = 1;
    my $flush = sub {
        my %r = (%base, boundaries => [@cur]);
        $r{turns} = $res->{turns} if $first;
        push @rows, \%r;
        $first = 0;
        @cur = ();
    };
    for my $x (@b) {
        push @cur, $x;
        my %probe = (%base, boundaries => [@cur], ($first ? (turns => $res->{turns}) : ()));
        if (length(watch::json::encode(\%probe)) > 3300 && @cur > 1) {
            pop @cur;
            $flush->();
            push @cur, $x;
        }
    }
    $flush->() if @cur || $first;
    if (@rows > 1) { my $i = 0; $_->{part} = ++$i for @rows }
    return @rows;
}

1;

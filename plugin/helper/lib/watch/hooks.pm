package watch::hooks;
# lib/watch/hooks.pm: rows written at hook time (WATCHER-SPEC W5, W6, W10, W11;
# §6.3 field lists). Owner: WP-watch. Nothing here prints: PreCompact stdout
# would become summarizer instructions (WATCH §0).
use strict;
use warnings;
use watch::ctx;
use watch::io;
use watch::json;
use watch::rows;
use watch::shape;
use watch::spec;

my $OPEN = "\xe2\x9f\xaa";    # U+27EA, the marker bracket
my $CLOSE = "\xe2\x9f\xab";   # U+27EB

sub _nonce_ok { return defined $_[0] && $_[0] =~ /\A[0-9a-f]{8}\z/ }

sub dispatch_record {
    my ($ctx, $nonce) = @_;
    return undef unless _nonce_ok($nonce);
    my $d = watch::io::read_json_file(watch::ctx::sid_dir($ctx) . "/dispatch/$nonce.json");
    return ref $d eq 'HASH' ? $d : undef;
}

sub _keyset_hash {
    my ($ctx, $payload) = @_;
    return $ctx->{keyset_hash} if defined $ctx->{keyset_hash};
    return undef unless ref $payload eq 'HASH';
    my $hex = watch::io::sha256_hex(join(',', sort keys %$payload), $ctx);
    return defined $hex ? substr($hex, 0, 8) : undef;
}

# A bracketed header line that is not ours (MOD §2.2: foreign headers never match).
sub foreign_header {
    my ($text, $spec) = @_;
    return 0 unless defined $text && index($text, $OPEN) >= 0;
    my @ours = grep { defined } map { watch::spec::regex($spec, $_) } qw(instr_marker_re marker_re sentinel_re);
    for my $line (split /\n/, $text) {
        next unless index($line, $OPEN) >= 0;
        my $l = $line;
        $l =~ s/$_//g for @ours;
        return 1 if $l =~ /\Q$OPEN\E[^\n]*?\Q$CLOSE\E/;
    }
    return 0;
}

sub _ci_nonce {
    my ($ctx, $ci) = @_;
    if (ref $ctx->{instr} eq 'HASH') {
        return _nonce_ok($ctx->{instr}{nonce}) ? $ctx->{instr}{nonce} : undef;
    }
    return undef unless defined $ci && length $ci;
    my $rx = watch::spec::regex($ctx->{spec}, 'instr_marker_re');
    return undef unless $rx;
    my $last;
    while ($ci =~ /$rx/g) { $last = $1 }
    return _nonce_ok($last) ? $last : undef;
}

# W5: `precompact {trigger, ci_bytes, ci_has_nonce, ci_nonce, ci_foreign_header, keyset_hash}`.
sub pre_compact {
    my ($ctx) = @_;
    my $p = $ctx->{payload};
    my $ci = defined $p->{custom_instructions} && !ref $p->{custom_instructions} ? $p->{custom_instructions} : undef;
    my $nonce = _ci_nonce($ctx, $ci);
    watch::ctx::log_row($ctx, 'precompact', {
        trigger           => _enum($p->{trigger}, qw(manual auto)),
        ci_bytes          => defined $ci ? length($ci) : 0,
        ci_has_nonce      => watch::ctx::B(defined $nonce),
        ci_nonce          => $nonce,
        ci_foreign_header => watch::ctx::B(foreign_header($ci, $ctx->{spec})),
        keyset_hash       => _keyset_hash($ctx, $p),
    });
}

sub _enum {
    my ($v, @ok) = @_;
    return undef unless defined $v && !ref $v;
    return (grep { $_ eq $v } @ok) ? $v : 'unknown';
}

sub _rows_of {
    my ($ctx) = @_;
    my @r;
    for my $f (watch::ctx::classic_log($ctx), watch::ctx::mod_log($ctx)) {
        push @r, @{ watch::io::read_jsonl($f) } if -f $f;
    }
    return \@r;
}

sub _strip_frontmatter {
    my ($t) = @_;
    return $t unless defined $t && $t =~ /\A---\n/;
    my $i = index($t, "\n---\n", 4);
    return $i >= 0 ? substr($t, $i + 5) : $t;
}

# The previous summary of the same chain: the newest saved copy of this
# session's same slot, else the newest earlier summary row in the transcript.
sub previous_summary {
    my ($ctx, $is_main, $nonce, $body, $rows) = @_;
    my ($best, $best_t);
    for my $r (@$rows) {
        next unless ($r->{ev} // '') eq 'copy';
        next unless ($r->{result} // '') =~ /\A(?:saved|exists|late)\z/;
        my $slot = $r->{slot} // '';
        next if $is_main ? $slot ne 'main' : $slot eq 'main';
        next if defined $nonce && defined $r->{nonce} && $r->{nonce} eq $nonce;
        my $t = watch::io::parse_iso($r->{ts}) // 0;
        if (!defined $best_t || $t >= $best_t) { $best = $r; $best_t = $t }
    }
    if ($best) {
        my $rel = $best->{rel_path} // $best->{copy_path} // $best->{path};
        if (defined $rel && !ref $rel && $rel !~ m{(?:\A|/)\.\.(?:/|\z)}) {
            my $path = $rel =~ m{\A/} ? $rel : $ctx->{root} . '/' . $rel;
            my $t = watch::io::slurp($path, 1 << 20);
            return (_strip_frontmatter($t), 'copy') if defined $t;
        }
    }
    my $tp = $ctx->{payload}{transcript_path};
    return (undef, 'none') unless defined $tp && !ref $tp && -f $tp;
    my @cands = @{ _summary_texts($tp, 5 << 20) };
    my $probe = length($body) > 120 ? substr($body, int(length($body) / 2), 60) : $body;
    for my $t (reverse @cands) {
        next if length $probe && index($t, $probe) >= 0;
        return ($t, 'transcript');
    }
    return (undef, 'none');
}

sub _summary_texts {
    my ($path, $max) = @_;
    my @out;
    open(my $fh, '<:raw', $path) or return \@out;
    my $size = -s $fh;
    my $from = $size > $max ? $size - $max : 0;
    seek($fh, $from, 0);
    <$fh> if $from > 0;
    while (my $line = <$fh>) {
        next unless index($line, $watch::rows::SUMMARY_HEAD) >= 0;
        my $r = eval { watch::json::decode($line) } or next;
        next unless ref $r eq 'HASH' && ($r->{type} // '') eq 'user' && ref $r->{message} eq 'HASH';
        my $c = $r->{message}{content};
        my $t = !ref $c ? $c : join('', map { ref $_ eq 'HASH' && defined $_->{text} ? $_->{text} : '' } @{ ref $c eq 'ARRAY' ? $c : [] });
        push @out, $t if defined $t && index($t, $watch::rows::SUMMARY_HEAD) == 0;
        shift @out if @out > 3;
    }
    close $fh;
    return \@out;
}

# MOD-SPEC §3.3 / WATCH M-06: did the mod write its liveness file in this turn,
# from this process? Core's answer wins when it passes one.
sub mod_alive_this_turn {
    my ($ctx) = @_;
    return $ctx->{mod_alive_this_turn} ? 1 : 0 if exists $ctx->{mod_alive_this_turn};
    my $alive = watch::io::read_json_file(watch::ctx::sid_dir($ctx) . '/mod-alive.json');
    return 0 unless ref $alive eq 'HASH';
    if (defined $ctx->{pid} && defined $alive->{pid}) {
        return 0 unless $alive->{pid} == $ctx->{pid};
        return 0 if defined $ctx->{pid_lstart} && defined $alive->{pid_lstart}
                    && "$alive->{pid_lstart}" ne "$ctx->{pid_lstart}";
    }
    # The mod's turn_id is the `turn.start` turnId, minted per turn; the
    # payload's prompt_id is a different id. Equal ids prove it; different ids
    # prove nothing, so the time test below decides.
    my $pid_prompt = $ctx->{payload}{prompt_id};
    if (defined $alive->{turn_id} && defined $pid_prompt && !ref $pid_prompt) {
        return 1 if "$alive->{turn_id}" eq "$pid_prompt";
    }
    my $at = watch::io::parse_iso($alive->{ts});
    return 0 unless defined $at;
    my $rows = watch::rows::tail_rows($ctx->{payload}{transcript_path}, 1 << 20, $ctx->{brand}, []);
    my ($start) = map { $_->{ts} } grep { ($_->{kind} // '') =~ /\A(?:prompt|continue)\z/ && defined $_->{ts} } reverse @$rows;
    return 0 unless defined $start;
    return $at >= $start - 2 ? 1 : 0;
}

# W6: `postcompact` with the shape metrics of compact_summary.
sub post_compact {
    my ($ctx) = @_;
    my $p = $ctx->{payload};
    my $text = defined $p->{compact_summary} && !ref $p->{compact_summary} ? $p->{compact_summary} : '';
    my $det = ref $ctx->{detect} eq 'HASH' ? $ctx->{detect} : undef;
    if (!$det && defined &detect::summary) {
        my $d = eval { local $SIG{__DIE__}; detect::summary($text, $ctx->{dispatch}) };
        $det = $d if ref $d eq 'HASH';
    }
    $det ||= {};
    my $body = defined $det->{normalized} ? $det->{normalized} : $text;
    my $nonce = _nonce_ok($det->{nonce}) ? $det->{nonce} : undef;
    my $disp = ref $ctx->{dispatch} eq 'HASH' ? $ctx->{dispatch} : dispatch_record($ctx, $nonce);
    my $scope = $det->{scope};
    my $is_main;
    if ($disp && defined $disp->{agent_id}) { $is_main = 0 }
    elsif (defined $scope && $scope eq 'sub') { $is_main = 0 }
    elsif (defined $scope && $scope =~ /\A(?:main|manual)\z/) { $is_main = 1 }
    else { $is_main = _looks_main($body, $ctx->{spec}) }
    my @tags = ref $disp eq 'HASH' && ref $disp->{tags} eq 'ARRAY' ? @{ $disp->{tags} } : ();
    my $measured = grep { $_ eq 'measured' } @tags;
    my $hhmm;
    if ($measured && $nonce) {
        my $cp = watch::io::read_json_file(watch::ctx::sid_dir($ctx) . "/checkpoint/$nonce.json");
        ($hhmm) = ($cp->{measured_block} // '') =~ /\b(\d\d:\d\d)\b/ if ref $cp eq 'HASH';
    }
    my $rows = _rows_of($ctx);
    my ($prev, $src) = previous_summary($ctx, $is_main, $nonce, $body, $rows);
    my $m = watch::shape::metrics(body => $body, spec => $ctx->{spec}, is_main => $is_main,
                                  measured => $measured, measured_hhmm => $hhmm, prev => $prev, prev_src => $src);
    my $verdict = $det->{verdict};
    my ($fp, $fp_new);
    if (!defined $nonce && (!defined $verdict || $verdict eq 'unshaped')) {
        $fp = watch::shape::arm_fp($body, $ctx);
        $fp_new = $fp ? watch::io::excl_create($ctx->{watch} . "/fingerprints/$fp.seen", '') : 0;
    }
    my $hits = $ctx->{secret_hits};
    if (!defined $hits && defined &secrets::scan) {
        my $s = eval { local $SIG{__DIE__}; secrets::scan($text) };
        $hits = [ map { ref $_ eq 'HASH' ? $_->{rule} : $_ } @$s ] if ref $s eq 'ARRAY';
    }
    $hits = [ grep { defined && !ref && /\A[A-Za-z0-9_.:-]{1,40}\z/ } @{ $hits || [] } ];
    my %seen;
    $hits = [ grep { !$seen{$_}++ } @$hits ];
    watch::ctx::log_row($ctx, 'postcompact', {
        trigger                 => _enum($p->{trigger}, qw(manual auto)),
        nonce_found             => $nonce,
        scope_found             => (defined $scope && $scope =~ /\A(?:main|sub|manual)\z/ ? $scope : undef),
        verdict                 => $verdict,
        marker_line             => $det->{marker_line},
        sentinel_from_end       => $det->{sentinel_from_end},
        summary_chars           => $m->{summary_chars},
        size_band               => $m->{size_band},
        form                    => ($is_main ? 'main' : 'sub'),
        main_headings           => _main_headings($body, $ctx->{spec}),
        section_chars           => $m->{section_chars},
        elements                => $m->{elements},
        fabricated_check_tokens => $m->{fabricated_check_tokens},
        measured                => watch::ctx::B($measured),
        ledger                  => $m->{ledger},
        clutter                 => $m->{clutter},
        tmp_paths               => $m->{tmp_paths},
        arm_fp                  => $fp,
        arm_new                 => (defined $fp ? watch::ctx::B($fp_new) : undef),
        secret_hits             => $hits,
        keyset_hash             => _keyset_hash($ctx, $p),
        mod_alive_this_turn     => watch::ctx::B(mod_alive_this_turn($ctx)),
    }, actor => ($disp && defined $disp->{actor} ? $disp->{actor} : 'unknown'));
}

sub _main_headings {
    my ($body, $spec) = @_;
    my @main = watch::spec::list($spec, q(sections_main));
    return undef unless @main;
    my $n = 0;
    for my $h (@main) { $n++ if length $h && $body =~ /^\Q$h\E/m }
    return $n;
}

sub _looks_main {
    my ($body, $spec) = @_;
    my @sub = watch::spec::list($spec, 'sections_subagent');
    my @main = watch::spec::list($spec, 'sections_main');
    my $has = sub { my $h = shift; return grep { length $_ && $body =~ /^\Q$_\E/m } @$h };
    return ($has->(\@sub) && !$has->(\@main)) ? 0 : 1;
}

# W10: `stop_failure {error_class}`; the class is the payload's error enum.
sub stop_failure {
    my ($ctx) = @_;
    my $e = $ctx->{payload}{error};
    my $class = defined $e && !ref $e && $e =~ /\A[a-z_]{1,40}\z/ ? $e : 'other';
    watch::ctx::log_row($ctx, 'stop_failure', { error_class => $class },
                        actor => (defined $ctx->{payload}{agent_id} ? 'unknown' : 'main'));
}

# W11: `permission_denied {tool_name, reason_class, guard_class, turn_kind, caused_by}`.
# Never tool_input, never the reason text.
sub permission_denied {
    my ($ctx) = @_;
    my $p = $ctx->{payload};
    my $tool = defined $p->{tool_name} && !ref $p->{tool_name} && $p->{tool_name} =~ /\A[A-Za-z0-9_.:-]{1,80}\z/
             ? $p->{tool_name} : 'other';
    my ($kind, $by) = ('other', 'session');
    unless (defined $p->{agent_id}) {
        my $rows = watch::rows::tail_rows($p->{transcript_path}, 512 << 10, $ctx->{brand}, []);
        ($kind, $by) = turn_kind($rows);
    }
    watch::ctx::log_row($ctx, 'permission_denied', {
        tool_name    => $tool,
        reason_class => 'other',
        guard_class  => 'other',
        turn_kind    => $kind,
        caused_by    => $by,
    }, actor => (defined $p->{agent_id} ? 'unknown' : 'main'));
}

sub turn_kind {
    my ($rows) = @_;
    my (@starts, $last_b, $last_inject, $last_heal);
    my $calls = 0;
    for my $i (0 .. $#$rows) {
        my $k = $rows->[$i]{kind} // '';
        push @starts, $i if $k eq 'prompt' || $k eq 'continue';
        $last_b = $i if $k eq 'boundary';
        if ($k eq 'continue' || $k eq 'nudge' || ($k eq 'hook_context' && ($rows->[$i]{hook_event} // '') eq 'SessionStart')) {
            $last_inject = $calls;
        }
        if ($k eq 'assistant') {
            for my $c (@{ $rows->[$i]{calls} || [] }) {
                $calls++;
                $last_heal = $calls if $c->{heal};
            }
        }
    }
    my $t = @starts ? $starts[-1] : -1;
    my $t2 = @starts > 1 ? $starts[-2] : -1;
    my $kind = 'other';
    if (defined $last_b && $last_b > $t2) { $kind = 'post-compaction' }
    elsif (grep { ($rows->[$_]{kind} // '') eq 'nudge' } ($t + 1 .. $#$rows)) { $kind = 'nudge' }
    elsif ($t >= 0 && $rows->[$t]{resume_invocation}) { $kind = 'resume' }
    my $by = 'session';
    $by = 'plugin' if defined $last_inject && $calls - $last_inject < 10;
    $by = 'plugin' if defined $last_heal && $calls - $last_heal < 10;
    return ($kind, $by);
}

1;

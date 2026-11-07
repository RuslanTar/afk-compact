package watch::shape;
# lib/watch/shape.pm: per-summary shape metrics, WATCHER-SPEC §3 M-08..M-13.
# Owner: WP-watch. Input is the normalized body from the core detector (one
# detector run, WATCH W6). Text is read in memory only; the result holds counts,
# classes and ids, never text (WATCH §8.2).
use strict;
use warnings;
use utf8;
use watch::spec;
use watch::io;

# Main section roles, by position in spec `sections_main` (the CONSISTENCY §1
# section order; `## Approvals` after User constraints since the 2026-10-23 scoped-approval
# ruling, AP-3). Used only when the spec lists exactly this many sections.
my @MAIN_ROLES = qw(resume_here user_constraints approvals decisions in_flight live_state
                    open_questions location work_done evidence next_steps);
my %NONE_ROLES = map { $_ => 1 } qw(user_constraints in_flight live_state open_questions);

sub chars {
    my ($bytes) = @_;
    return 0 unless defined $bytes;
    my $c = $bytes;
    utf8::decode($c);
    return length $c;
}

sub _slug {
    my ($h) = @_;
    (my $s = lc $h) =~ s/^#+\s*//;
    $s =~ s/[^a-z0-9]+/_/g;
    $s =~ s/^_+|_+$//g;
    my @w = grep { length } split /_/, $s;
    @w = @w[0 .. 2] if @w > 3;
    return join('_', @w) || 'other';
}

# Split at heading literals matched as a prefix of a `#` line (MOD §5.1).
# Returns [ {key, role, index, lines => [..]} ... ]; the part before the first
# known heading is `preamble`, unknown headings are `other`.
sub split_sections {
    my ($body, $headings, $roles) = @_;
    my @parts = ({ key => 'preamble', role => undef, index => -1, lines => [] });
    for my $line (split /\n/, $body) {
        if ($line =~ /^#/) {
            my $hit;
            for my $i (0 .. $#$headings) {
                my $h = $headings->[$i];
                if (length $h && index($line, $h) == 0) { $hit = $i; last }
            }
            if (defined $hit) {
                push @parts, { key => _slug($headings->[$hit]), role => ($roles ? $roles->[$hit] : undef),
                               index => $hit, lines => [] };
                next;
            }
            if ($line =~ /^##/) {
                push @parts, { key => 'other', role => undef, index => -1, lines => [] };
                next;
            }
        }
        push @{ $parts[-1]{lines} }, $line;
    }
    return \@parts;
}

sub size_band {
    my ($n, $is_main) = @_;
    if ($is_main) {
        return $n < 6000 ? 'under-6K' : $n < 10000 ? '6-10K' : $n <= 12000 ? '10-12K' : 'over-12K';
    }
    return $n < 2000 ? 'under-2K' : $n <= 4000 ? '2-4K' : 'over-4K';
}

# RV-24 (small-rulings §3a): a stamp is `YYYY-MM-DD HH:MM ±hhmm`, regex `time_re` of the
# spec asset; the legacy short forms (`HH:MM`, `MM-DD HH:MM`, `time_legacy_re`) are still read
# and counted, never written. The fallbacks below only serve a spec without the keys.
my $TIME_RE = '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}';
my $LEGACY_RE = '(?:[0-9]{2}-[0-9]{2} )?[0-9]{2}:[0-9]{2}';
# M-10 only: a date plus a time that is not a whole stamp (no zone, `+hh:mm`, ISO `T`/`Z`).
my $NEAR_RE = qr/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(?![0-9])/;

sub time_res {
    my ($spec) = @_;
    my $full = watch::spec::regex($spec || {}, 'time_re') || qr/$TIME_RE/;
    my $legacy = watch::spec::regex($spec || {}, 'time_legacy_re') || qr/$LEGACY_RE/;
    return ($full, $legacy);
}

# The stamps of a measured block (the checkpoint's `measured_block`): its header's stamp
# first (core prints `Measured facts (<stamp or ISO time>):`), then every other whole stamp
# in the block (`In flight (sidecar <stamp>)`); a block with no whole stamp gives its first
# legacy `HH:MM`. The model may copy any of them (the instructions allow checked times
# taken from Measured facts), so a token equal to one of them is not fabricated.
sub measured_stamps {
    my ($block, $spec) = @_;
    return () unless defined $block && !ref $block && length $block;
    my ($full, $legacy) = time_res($spec);
    my @out;
    my $add = sub { my $t = shift; push @out, $t if defined $t && !grep { $_ eq $t } @out };
    my ($head) = split /\n/, $block, 2;
    if ($head =~ /($full)/) { $add->($1) }
    elsif ($head =~ /\b([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2})(?::[0-9]{2}(?:\.[0-9]+)?)?([+-])([0-9]{2}):?([0-9]{2})\b/) {
        $add->("$1 $2 $3$4$5");
    }
    while ($block =~ /($full)/g) { $add->($1) }
    unless (@out) { $add->($1) if $block =~ /\b([0-9]{2}:[0-9]{2})\b/ }
    return @out;
}

# M-10: `checked <stamp>` and `[verified <stamp>` tokens, in the stamp form and in the legacy
# short forms. With a measured block, a token whose whole text equals one of the block's
# stamps does not count (`$stamps`, from measured_stamps). `listed` never counts.
sub fabricated {
    my ($body, $measured, $stamps, $spec) = @_;
    my ($full, $legacy) = time_res($spec);
    my %ok = map { $_ => 1 } grep { defined } @{ ref $stamps eq 'ARRAY' ? $stamps : [] };
    my $n = 0;
    my $count = sub {
        my $t = shift;
        $n++ unless $measured && defined $t && $ok{$t};
    };
    # A near-stamp (a date and a time with the zone dropped or in another form, e.g.
    # `2026-10-21 14:05`, `... +03:00`, `2026-10-21T14:05:12Z`) is a check time too and
    # counts, as `[verified <near-stamp>` does below (CR-F16); it never equals a whole stamp.
    # Numbered captures only (PKG-RUNTIME B.5): `%+` loads Tie::Hash::NamedCapture, which
    # perl-base 5.28 (Debian 10) lacks. Each form is tried at the same place in the order the
    # alternation had (whole stamp, near-stamp, legacy), each with its own `$1`, so a capture
    # group inside a spec regex (`time_legacy_re` has one) never shifts the numbering.
    while ($body =~ /\bchecked /g) {
        my $at = pos $body;
        my $t;
        if ($body =~ /\G($full)/gc || $body =~ /\G($NEAR_RE)/gc || $body =~ /\G($legacy)(?![0-9])/gc) {
            $t = $1;
        } else {
            pos($body) = $at;
            next;
        }
        $count->($t);
    }
    while ($body =~ /\[verified /g) {
        my $t;
        if ($body =~ /\G($full)/gc) {
            $t = $1;
        } else {
            if ($body =~ /\G([^\]\n]{0,40})/gc) {
                my $o = $1;
                $t = $1 if $o =~ /\b($legacy)(?![0-9])/;
            }
        }
        $count->($t);
    }
    return $n;
}

my $ID_RE = qr/\b([UDX])-([0-9]+)\b/;
# between the ids of a list: spaces, `,` `/` `&` `+`, the words and/or/to/through, an en dash
my $LIST_SEP = qr/(?:\s|,|\/|&|\+|\b(?:and|or|to|through)\b|\xe2\x80\x93)/;

# 0.1.4 (stable ledger, watcher side): an entry's text with its id, the separator after it, the
# bullet, trailing check stamps (`checked <stamp>`, `[verified <stamp>]`, `(<stamp>)`, a bare
# stamp; whole, near or legacy form) and the separators before them removed, ASCII case and
# whitespace folded. Two entries with the same normalised text are the same line.
my $SEP = qr/(?:\s|,|;|\xc2\xb7|\xe2\x80\x94|\xe2\x80\x93|-)*/;
sub norm_entry {
    my ($line, $spec) = @_;
    my ($full, $legacy) = time_res($spec);
    my $stamp = qr/(?:$full|$NEAR_RE(?::[0-9]{2}(?:\.[0-9]+)?)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?|$legacy)/;
    my $t = $line;
    $t =~ s/\A\s*(?:[-*]\s+)?//;
    $t =~ s/\A[UDX]-[0-9]+\b(?:\s*(?::|\.|\)|\xe2\x80\x94|-))?\s*//;
    1 while $t =~ s/$SEP(?:\[\s*verified\s+$stamp[^\]\n]{0,40}\]|\(\s*(?:checked\s+|verified\s+)?$stamp\s*\)|(?:checked|verified)\s+$stamp|$stamp)\s*\z//i;
    $t = lc $t;
    $t =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    return $t;
}

# Ledger entries are lines that start with an id (after an optional bullet).
sub _ledger {
    my ($body, $fold_rx, $spec) = @_;
    my (%entries, %named, %carried, %text, %by_text, $chars, @other);
    $chars = 0;
    my $folded = 0;
    for my $line (split /\n/, $body) {
        my $t = $line;
        $t =~ s/^\s*(?:[-*]\s+)?//;
        my $is_fold = $fold_rx && $line =~ $fold_rx;
        if ($t =~ /\ASuperseded:/ || $line =~ /\bSuperseded:/ || $is_fold) {
            (my $s = $line) =~ s/\b[UDX]-[0-9]+\s*(?:\.\.|\xe2\x80\xa6)\s*[UDX]-[0-9]+\b//g;
            while ($s =~ /$ID_RE/g) {
                my $id = "$1-$2";
                $folded++ if $is_fold && !$named{$id};
                $named{$id} = 1;
            }
            next;
        }
        if ($t =~ /\A([UDX])-([0-9]+)\b/) {
            my $id = "$1-$2";
            $entries{$id} = 1;
            # the other ids an entry line carries: the id list it starts with (`U-2, U-3, U-10:
            # carried`, `U-51/U-52: done`) and the id list each of its merged clauses starts with
            # (`U-33 "1a" R1354; U-34 "2,3,4" R1355`, `U-59: done · U-61: done`), ranges left out as
            # on a fold line; an id the text only cites (`per U-32`) is not carried
            (my $s = $t) =~ s/\b[UDX]-[0-9]+\s*(?:\.\.|\xe2\x80\xa6)\s*[UDX]-[0-9]+\b//g;
            for my $clause (split /;|\xc2\xb7|\|/, $s) {
                while ($clause =~ /\G$LIST_SEP*([UDX])-([0-9]+)\b/gc) { $carried{"$1-$2"} = 1 }
            }
            my $nt = norm_entry($line, $spec);
            if (length $nt) { $text{$id} //= $nt; $by_text{$nt} //= $id }
            $chars += chars($line) + 1;
            next;
        }
        next if $t =~ /\AQ-[0-9]+\b/;
        my $o = $line;
        $o =~ s/^\s+|\s+$//g;
        push @other, $o if length $o;
    }
    return { entries => \%entries, named => \%named, chars => $chars, folded => $folded, other => \@other,
             text => \%text, by_text => \%by_text, carried => \%carried };
}

# 0.1.5 (E-1, stable ledger): a saved copy's body without the ledger lines the helper carried into
# it, given its `ledger_carried` value (`<n> lines (U-3, D-2, ab12cd34:D-1); sha256 <hex>`, maybe
# JSON-quoted). The helper carries a line into User constraints or Decisions only when the
# summary's User constraints, Approvals and Decisions named none of its ids, so every line of those
# two sections that names one is a carried line, read with the reader that chose them
# (ledger::line_ids, with the spec's fold line and carry tag as characters, as the helper reads
# them); a line of another section is the summary's own. lib/ledger.pm ships beside the watcher;
# were it missing, a line led by a carried id would still be dropped.
sub uncarried {
    my ($body, $note, $spec) = @_;
    return $body unless defined $body && defined $note && !ref $note;
    (my $ids = $note) =~ s/sha256.*\z//s;
    my %c;
    $c{ (defined $1 ? "$1:" : '') . "$2-" . ($3 + 0) } = 1 while $ids =~ /(?:\b([0-9a-f]{8}):)?\b([UDX])-0*([0-9]+)\b/g;
    return $body unless %c;
    my $lib = eval { require ledger; 1 };
    my $sp = ref $spec eq 'HASH' ? $spec : {};
    my $carry = ref $sp->{carry} eq 'HASH' ? $sp->{carry} : {};
    # The JSON reader keeps strings as bytes; the lines are read as characters, so the patterns are too
    # (the tag's ` · ` is not ASCII).
    my $chars = sub { my $v = $_[0]; $v = $v->[0] if ref $v eq 'ARRAY'; return undef if !defined $v || ref $v;
                      utf8::decode($v) unless utf8::is_utf8($v); return watch::spec::compile($v) };
    my %o = (fold_re => $chars->($sp->{fold_line_re}), tag_re => $chars->($carry->{tag_re}));
    my $sid = ref $sp->{section_ids} eq 'HASH' ? $sp->{section_ids} : {};
    my @ledger = grep { ($sid->{$_} // '') =~ /\Amain:(?:user-constraints|decisions)\z/ } keys %$sid;
    my $in = @ledger ? 0 : 1;
    my @keep;
    for my $line (split /\n/, $body, -1) {
        if (@ledger && $line =~ /\A##\s/ && $line !~ /\A###/) {
            $in = (grep { index($line, $_) == 0 } @ledger) ? 1 : 0;
            push @keep, $line;
            next;
        }
        if ($in) {
            my $c = $line;
            utf8::decode($c);
            my @ids = $lib ? @{ ledger::line_ids($c, \%o)->{ids} || [] }
                    : $c =~ /\A\s*(?:[-*]\s+)?([UDX])-0*([0-9]+)\b/ ? ("$1-" . ($2 + 0)) : ();
            next if grep { $c{$_} } @ids;
        }
        push @keep, $line;
    }
    return join "\n", @keep;
}

# M-11 against the previous summary text (or undef). 0.1.4: an old id is lost only when the new
# ledger has neither the id (as an entry, in the id list another entry line or one of its merged
# clauses starts with, or named on a Superseded/fold line) nor an entry with the same normalised
# text (norm_entry); such a line under another id counts as `renumbered`, an id in another entry
# line's id list as `carried`.
sub ledger_diff {
    my ($body, $prev, $src, $spec) = @_;
    my $fold_rx = watch::spec::regex($spec, 'fold_line_re');
    my $cur = _ledger($body, $fold_rx, $spec);
    unless (defined $prev) {
        return { lost_U => undef, lost_D => undef, lost_X => undef, renumbered => undef, carried => undef,
                 folded => $cur->{folded}, ledger_chars => $cur->{chars}, overlap_pct => undef, ledger_src => 'none' };
    }
    my $old = _ledger($prev, $fold_rx, $spec);
    my %lost = (U => 0, D => 0, X => 0);
    my ($renumbered, $carried) = (0, 0);
    for my $id (keys %{ $old->{entries} }) {
        next if $cur->{entries}{$id} || $cur->{named}{$id};
        if ($cur->{carried}{$id}) { $carried++; next }
        my $nt = $old->{text}{$id};
        if (defined $nt && $cur->{by_text}{$nt}) { $renumbered++; next }
        $lost{ substr($id, 0, 1) }++;
    }
    my %prev_lines = map { $_ => 1 } @{ $old->{other} };
    my $n = scalar @{ $cur->{other} };
    my $same = grep { $prev_lines{$_} } @{ $cur->{other} };
    return { lost_U => $lost{U}, lost_D => $lost{D}, lost_X => $lost{X}, renumbered => $renumbered, carried => $carried,
             folded => $cur->{folded},
             ledger_chars => $cur->{chars}, overlap_pct => ($n ? int(100 * $same / $n + 0.5) : 0),
             ledger_src => $src };
}

# M-13: chars matched per class, over the whole body (classes may span lines).
sub clutter {
    my ($body, $spec) = @_;
    my $classes = watch::spec::classes($spec, 'clutter_classes');
    return (undef, undef) unless @$classes;
    my (%c, $tmp);
    for my $cl (@$classes) {
        my ($id, $rx) = @$cl;
        my ($n, $hits) = (0, 0);
        while ($body =~ /$rx/g) {
            my $len = $+[0] - $-[0];
            last if $len == 0 && ++$hits > 10000;
            $n += $len;
            $hits++;
        }
        $c{$id} = $n;
        $tmp = ($tmp // 0) + $hits if $id =~ /tmp/i;
    }
    return (\%c, $tmp);
}

# arm_fp: sha256/12 of the ordered `#`..`###` heading lines, digits normalised.
sub arm_fp {
    my ($body, $ctx) = @_;
    my @h = grep { /^#{1,3} / } split /\n/, $body;
    s/[0-9]+/N/g for @h;
    my $hex = watch::io::sha256_hex(join("\n", @h), $ctx);
    return defined $hex ? substr($hex, 0, 12) : undef;
}

# M-09 elements (main summaries; needs the role map).
sub elements {
    my ($parts, $spec) = @_;
    my %by;
    for my $p (@$parts) { $by{ $p->{role} } ||= $p if defined $p->{role} }
    return undef unless %by;
    my %e;
    my $nonblank = sub { my $p = shift; return $p ? [ grep { /\S/ } @{ $p->{lines} } ] : [] };

    my $rh = $nonblank->($by{resume_here});
    $e{resume_here_lines} = scalar @$rh;
    $e{resume_here_le5} = (@$rh && @$rh <= 5) ? \1 : \0;

    my %words = map { $_ => 1 } watch::spec::list($spec, 'status_words');
    if (%words) {
        my ($title) = grep { /^# / } @{ $parts->[0]{lines} };
        my $ok = 0;
        if (defined $title) {
            for my $w (keys %words) { if ($title =~ /(?<![A-Za-z-])\Q$w\E(?![A-Za-z-])/) { $ok = 1; last } }
        }
        $e{status_word_ok} = $ok ? \1 : \0;
    }

    my ($step1) = map { /^\s*Step 1:\s*(.*)$/ ? $1 : () } @$rh;
    $e{step1_present} = defined $step1 ? \1 : \0;
    if (defined $step1) {
        (my $cmd = $step1) =~ s/\s+\xe2\x80\x94\s+for\s.*$//;
        $cmd =~ s/\s+\|\s*proposed\s*$//;
        $cmd =~ s/^\s+|\s+$//g;
        my ($first) = map { /^\s*1\.\s*(.*)$/ ? $1 : () } @{ $nonblank->($by{next_steps}) };
        $e{step1_matches_next} = (defined $first && length $cmd && index($first, $cmd) == 0) ? \1 : \0;
    }

    my @none = watch::spec::list($spec, 'none_forms_compaction');
    my $missing = 0;
    for my $role (sort keys %NONE_ROLES) {
        my $p = $by{$role};
        if (!$p) { $missing++; next }
        my $lines = $nonblank->($p);
        $missing++ unless @$lines;
    }
    $e{none_sections_missing} = $missing;
    if (@none) {
        my $forms = 0;
        for my $role (sort keys %NONE_ROLES) {
            my $p = $by{$role} or next;
            my $text = join "\n", @{ $p->{lines} };
            $forms++ if grep { length $_ && index($text, $_) >= 0 } @none;
        }
        $e{none_forms_used} = $forms;
    }

    # In-flight rows and the `+N more` marker by the spec's own literals
    # (inflight_compact_row_re, more_compaction_re, inflight_max_rows; BUILD-PLAN
    # §3.4): a missing literal leaves its element null.
    my $row_rx = watch::spec::regex($spec, 'inflight_compact_row_re');
    my $more_rx = watch::spec::regex($spec, 'more_compaction_re');
    my $max = $spec->{inflight_max_rows};
    $max = undef unless defined $max && !ref $max && $max =~ /\A[0-9]+\z/;
    my ($rows, $more) = (0, 0);
    for my $l (@{ $nonblank->($by{in_flight}) }) {
        $rows++ if $row_rx && $l =~ $row_rx;
        $more = 1 if $more_rx && $l =~ $more_rx;
    }
    $e{inflight_rows} = $row_rx ? $rows : undef;
    $e{inflight_over_8} = ($row_rx && defined $max) ? ($rows > $max ? \1 : \0) : undef;
    $e{inflight_more_marker} = $more_rx ? ($more ? \1 : \0) : undef;

    my $nob = 0;
    for my $l (@{ $nonblank->($by{decisions}) }) {
        $nob++ if $l =~ /^\s*(?:[-*]\s+)?D-[0-9]+\b/ && $l !~ /\bbecause\b/;
    }
    $e{decisions_without_because} = $nob;

    my $norc = 0;
    my @none_live = @none;
    for my $l (@{ $nonblank->($by{live_state}) }) {
        next if grep { length $_ && index($l, $_) >= 0 } @none_live;
        $norc++ unless $l =~ /\bre-check\b/;
    }
    $e{live_rows_without_recheck} = $norc;
    return \%e;
}

# All shape metrics for one summary.
sub metrics {
    my (%a) = @_;
    my $body = defined $a{body} ? $a{body} : '';
    my $spec = $a{spec} || {};
    my $is_main = $a{is_main};
    my @main = watch::spec::list($spec, 'sections_main');
    my @sub = watch::spec::list($spec, 'sections_subagent');
    my $headings = $is_main ? \@main : \@sub;
    my $roles = ($is_main && @main == @MAIN_ROLES) ? \@MAIN_ROLES : undef;
    my $parts = split_sections($body, $headings, $roles);
    my %sec;
    if (@$headings) {
        for my $p (@$parts) {
            my $n = 0;
            $n += chars($_) + 1 for @{ $p->{lines} };
            $sec{ $p->{key} } += $n;
        }
    }
    my $total = chars($body);
    my ($clutter, $tmp) = clutter($body, $spec);
    my %m = (
        summary_chars           => $total,
        size_band               => size_band($total, $is_main),
        section_chars           => (@$headings ? \%sec : undef),
        elements                => ($is_main && $roles ? elements($parts, $spec) : undef),
        fabricated_check_tokens => fabricated($body, $a{measured}, $a{measured_stamps}, $spec),
        ledger                  => ledger_diff($body, $a{prev}, $a{prev_src}, $spec),
        clutter                 => $clutter,
        tmp_paths               => $tmp,
    );
    return \%m;
}

1;

package watch::shape;
# lib/watch/shape.pm: per-summary shape metrics, WATCHER-SPEC §3 M-08..M-13.
# Owner: WP-watch. Input is the normalized body from the core detector (one
# detector run, WATCH W6). Text is read in memory only; the result holds counts,
# classes and ids, never text (WATCH §8.2).
use strict;
use warnings;
use watch::spec;
use watch::io;

# Main section roles, by position in spec `sections_main` (the CONSISTENCY §1
# section order). Used only when the spec lists exactly this many sections.
my @MAIN_ROLES = qw(resume_here user_constraints decisions in_flight live_state
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

# M-10: `checked HH:MM` and `[verified ` tokens; with a measured block, only
# tokens whose HH:MM differs from the measured time count. `listed` never.
sub fabricated {
    my ($body, $measured, $measured_hhmm) = @_;
    my $n = 0;
    while ($body =~ /\bchecked (\d\d:\d\d)\b/g) {
        $n++ unless $measured && defined $measured_hhmm && $1 eq $measured_hhmm;
    }
    while ($body =~ /\[verified ([^\]\n]{0,40})/g) {
        my ($t) = $1 =~ /(\d\d:\d\d)/;
        $n++ unless $measured && defined $measured_hhmm && defined $t && $t eq $measured_hhmm;
    }
    return $n;
}

my $ID_RE = qr/\b([UDX])-([0-9]+)\b/;

# Ledger entries are lines that start with an id (after an optional bullet).
sub _ledger {
    my ($body, $fold_rx) = @_;
    my (%entries, %named, $chars, @other);
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
            $entries{"$1-$2"} = 1;
            $chars += chars($line) + 1;
            next;
        }
        next if $t =~ /\AQ-[0-9]+\b/;
        my $o = $line;
        $o =~ s/^\s+|\s+$//g;
        push @other, $o if length $o;
    }
    return { entries => \%entries, named => \%named, chars => $chars, folded => $folded, other => \@other };
}

# M-11 against the previous summary text (or undef).
sub ledger_diff {
    my ($body, $prev, $src, $spec) = @_;
    my $fold_rx = watch::spec::regex($spec, 'fold_line_re');
    my $cur = _ledger($body, $fold_rx);
    unless (defined $prev) {
        return { lost_U => undef, lost_D => undef, lost_X => undef, folded => $cur->{folded},
                 ledger_chars => $cur->{chars}, overlap_pct => undef, ledger_src => 'none' };
    }
    my $old = _ledger($prev, $fold_rx);
    my %lost = (U => 0, D => 0, X => 0);
    for my $id (keys %{ $old->{entries} }) {
        next if $cur->{entries}{$id} || $cur->{named}{$id};
        $lost{ substr($id, 0, 1) }++;
    }
    my %prev_lines = map { $_ => 1 } @{ $old->{other} };
    my $n = scalar @{ $cur->{other} };
    my $same = grep { $prev_lines{$_} } @{ $cur->{other} };
    return { lost_U => $lost{U}, lost_D => $lost{D}, lost_X => $lost{X}, folded => $cur->{folded},
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

    my $rows = 0;
    my $more = 0;
    for my $l (@{ $nonblank->($by{in_flight}) }) {
        $rows++ if $l =~ /^\s*(?:[-*|]\s*)?B-[0-9]+\b/;
        $more = 1 if $l =~ /\+[0-9]+ more\b/;
    }
    $e{inflight_rows} = $rows;
    $e{inflight_over_8} = $rows > 8 ? \1 : \0;
    $e{inflight_more_marker} = $more ? \1 : \0;

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
        fabricated_check_tokens => fabricated($body, $a{measured}, $a{measured_hhmm}),
        ledger                  => ledger_diff($body, $a{prev}, $a{prev_src}, $spec),
        clutter                 => $clutter,
        tmp_paths               => $tmp,
    );
    return \%m;
}

1;

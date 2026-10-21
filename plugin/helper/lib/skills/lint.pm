package skills::lint;
# lib/skills/lint.pm: the publish lint of TPL §7. It flags and never edits.
# Headings and the marker grammar come from assets/handoff-spec.json; the
# secret rules from the core secrets seam.
#
# lint(\%in) → {blocking => [[rule, where]…], advisory => [[rule, where]…]}
# %in: body, recipes {name => text}, extra {name => text} (ledger, inflight),
#      previous (text of previous_handoff or undef), times {shown => 1},
#      evidence [rows], bucket, brand.
use strict;
use warnings;
use skills::spec;
use skills::core;

# Ephemeral locations (TPL §5 "Rule").
my $PATH_CH = qr{[^\s`'"<>()\[\],;]};
# An ephemeral path starts the path: `/tmp/` inside a longer path is not one.
my $START = qr{(?<![\w.\/~-])};
my @EPHEMERAL = (qr{$START/private/tmp/$PATH_CH+}, qr{$START/tmp/$PATH_CH+}, qr{$START/private/var/folders/$PATH_CH+},
                 qr{$START/var/folders/$PATH_CH+}, qr{(?<![\w/])tasks/$PATH_CH+\.output\b});

sub lint {
    my ($in) = @_;
    my (@block, @adv);
    my $body = $in->{body} // '';
    my @lines = split /\n/, $body, -1;
    my %prev_lines = map { $_ => 1 } split /\n/, ($in->{previous} // '');
    my $mains = skills::spec::sections_main();
    my $locs = skills::spec::sections_location();
    my $nf = skills::spec::none_forms();

    # ---- section map
    my (@secs, $cur);
    my $title_ok = 0;
    my $first_content;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        my $n = $i + 1;
        $first_content //= $n if $l =~ /\S/;
        if ($l =~ /\A#\s+\S/ && $l !~ /\A##/) {
            $title_ok = 1 if defined $first_content && $first_content == $n;
            next;
        }
        if ($l =~ /\A##\s/ && $l !~ /\A###/) {
            my ($idx) = grep { index($l, $mains->[$_]{literal}) == 0 } 0 .. $#$mains;
            $cur = { idx => $idx, line => $n, text => $l, body => [], subs => [] };
            push @secs, $cur;
            next;
        }
        if ($l =~ /\A###\s/ && $cur) {
            my ($li) = grep { index($l, $locs->[$_]{literal}) == 0 } 0 .. $#$locs;
            push @{ $cur->{subs} }, { idx => $li, line => $n, text => $l };
        }
        push @{ $cur->{body} }, [ $n, $l ] if $cur;
    }
    my %by_name;
    $by_name{ $mains->[ $_->{idx} ]{name} } //= $_ for grep { defined $_->{idx} } @secs;

    # ---- headings missing, renamed or out of order
    push @block, [ 'headings', 'title' ] unless $title_ok;
    my $last = -1;
    my $loc_name;
    if (@$locs) {
        # The section that holds the location subsections (Location).
        for my $s (@secs) { if (grep { defined $_->{idx} } @{ $s->{subs} }) { $loc_name = defined $s->{idx} ? $mains->[ $s->{idx} ]{name} : undef; last } }
    }
    for my $s (@secs) {
        if (!defined $s->{idx}) { push @block, [ 'headings', "line $s->{line}" ]; next }
        if ($s->{idx} <= $last) { push @block, [ 'headings', "line $s->{line}" ]; next }
        $last = $s->{idx};
    }
    my %required = map { $_ => 1 } keys %$nf;
    if (@$mains) { $required{ $mains->[0]{name} } = 1; $required{ $mains->[-1]{name} } = 1 }
    $required{$loc_name} = 1 if defined $loc_name;
    for my $m (@$mains) {
        push @block, [ 'headings', "missing $m->{name}" ] if $required{ $m->{name} } && !$by_name{ $m->{name} };
    }
    for my $s (@secs) {
        my $sl = -1;
        for my $sub (@{ $s->{subs} }) {
            my $in_loc = defined $s->{idx} && defined $loc_name && $mains->[ $s->{idx} ]{name} eq $loc_name;
            next if !defined $sub->{idx} && !$in_loc;
            if (!defined $sub->{idx} || !$in_loc || $sub->{idx} <= $sl) { push @block, [ 'headings', "line $sub->{line}" ]; next }
            $sl = $sub->{idx};
        }
    }
    for my $i (0 .. $#lines) {
        push @block, [ 'update-heading', 'line ' . ($i + 1) ] if $lines[$i] =~ /\A#+\s.*(?:\bUPDATE\b|\baddend(?:um|a)\b)/i;
    }

    # ---- frontmatter, marker or sentinel in the draft
    my ($mre, $sre) = (skills::spec::marker_re(), skills::spec::sentinel_re());
    my $b = $in->{brand} // '';
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        my $hit = ($i == 0 && $l =~ /\A---\s*\z/)
            || ($mre && $l =~ $mre) || ($sre && $l =~ $sre)
            || ($b ne '' && (index($l, "\x{e2}\x{9f}\x{aa}$b v1 ") >= 0 || index($l, "\x{e2}\x{9f}\x{aa}/$b n=") >= 0));
        push @block, [ 'meta-in-draft', 'line ' . ($i + 1) ] if $hit;
    }

    # ---- Resume here: ≤5 lines; Step 1 equals Next steps item 1
    my $rh = @$mains ? $by_name{ $mains->[0]{name} } : undef;
    my $ns = @$mains ? $by_name{ $mains->[-1]{name} } : undef;
    if ($rh) {
        my @c = grep { $_->[1] =~ /\S/ } @{ $rh->{body} };
        push @block, [ 'resume-lines', "line $rh->{line}" ] if @c > 5;
    }
    if ($rh && $ns) {
        my ($s1) = map { $_->[1] =~ /\A\s*Step 1:\s*(.*)\z/ ? $1 : () } @{ $rh->{body} };
        my ($n1) = map { $_->[1] =~ /\A\s*1\.\s+(.*)\z/ ? $1 : () } @{ $ns->{body} };
        if (defined $s1) {
            $s1 =~ s/\s+\x{e2}\x{80}\x{94}\s+for\b.*\z//;
            $s1 =~ s/\s*\|?\s*proposed\s*\z//;
            $s1 =~ s/\A\s+|\s+\z//g;
        }
        if (defined $n1) {
            $n1 =~ s/\s+\x{e2}\x{80}\x{94}\s+done when\b.*\z//;
            $n1 =~ s/\A\s+|\s+\z//g;
        }
        push @block, [ 'step1-mismatch', "line $rh->{line}" ] if !defined $s1 || !defined $n1 || $s1 ne $n1;
    }

    # ---- none-sections need content or their none-form
    for my $name (sort keys %$nf) {
        my $s = $by_name{$name} or next;
        my @c = grep { $_->[1] =~ /\S/ } @{ $s->{body} };
        push @block, [ 'none-form', $name ] unless @c;
    }

    # ---- ephemeral paths: durable copy or Volatile:
    my %covered;
    for my $r (@{ $in->{evidence} || [] }) {
        next unless ($r->{status} // '') =~ /\A(copied|dup|redacted|ref-only)\z/;
        $covered{$_} = 1 for grep { defined } $r->{src}, $r->{origin};
    }
    my %volatile;
    for my $l (@lines) {
        next unless $l =~ /\A\s*[-*]?\s*Volatile:\s*(.*)\z/;
        my $v = $1;
        for my $re (@EPHEMERAL) { while ($v =~ /($re)/g) { $volatile{ _trim_path($1) } = 1 } }
    }
    my %seen;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next if $l =~ /\A\s*[-*]?\s*Volatile:/;
        for my $re (@EPHEMERAL) {
            while ($l =~ /($re)/g) {
                my $p = _trim_path($1);
                next if $seen{$p}++;
                next if $volatile{$p} || _covered($p, \%covered);
                push @block, [ 'ephemeral-path', 'line ' . ($i + 1) ];
            }
        }
    }

    # ---- Live state rows need an as-of
    my ($ls_name) = grep { /\ALive state/ } map { $_->{name} } @$mains;
    if ($ls_name && (my $ls = $by_name{$ls_name})) {
        my $hdr = 0;
        for my $r (@{ $ls->{body} }) {
            my $l = $r->[1];
            next unless $l =~ /\A\s*\|/;
            next if $l =~ /\A\s*\|\s*:?-{2,}/;
            if (!$hdr++) { next }
            my @cells = split /\|/, $l;
            shift @cells;
            push @block, [ 'live-asof', "line $r->[0]" ] if @cells < 2 || $cells[1] !~ /\S/;
        }
    }

    # ---- checked / verified times only from the helper
    my $times = $in->{times} || {};
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next if $prev_lines{$l};
        while ($l =~ /(?:\bchecked|\[verified)\s+((?:\d\d-\d\d\s+)?\d\d:\d\d)\b/g) {
            push @block, [ 'unprinted-time', 'line ' . ($i + 1) ] unless $times->{$1};
        }
    }

    # ---- id ranges
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        if ($l =~ /\b([UDXQB])-\d+\s*(?:\.\.\.?|\x{e2}\x{80}\x{93}|\bto\b)\s*(?:\1-)?\d+\b/ || $l =~ /\b([UDXQB])-\d+-\1-\d+\b/) {
            push @block, [ 'id-range', 'line ' . ($i + 1) ];
        }
    }

    # ---- recipes
    my %durable = map { $_->{copy} => 1 } grep { $_->{copy} && ($_->{where} // '') eq 'keep' } @{ $in->{evidence} || [] };
    for my $name (sort keys %{ $in->{recipes} || {} }) {
        my $t = $in->{recipes}{$name};
        my $n = 0;
        for my $l (split /\n/, $t) {
            $n++;
            push @block, [ 'recipe-placeholder', "restart/$name:$n" ]
                if $l =~ /<[A-Za-z][A-Za-z ,;:'|-]{0,80}>/ || $l =~ /\b(?:TODO|TBD|FIXME)\b/;
            if ($l =~ /\A\s*script:\s*(\S+)/) {
                my $sp = $1;
                next if $sp =~ /\Anone\z/i;
                my $abs = $sp =~ m{\A/} ? $sp : "$in->{bucket}/$sp";
                push @block, [ 'recipe-script', "restart/$name:$n" ] unless $durable{$abs};
            }
            if ($l =~ /\A\s*spawns:\s*(.*)\z/) {
                my $v = $1;
                push @block, [ 'recipe-spawn', "restart/$name:$n" ] if $v =~ /agent/i && !($v =~ /\bmodel\s+\S/ && $v =~ /\beffort\s+\S/);
            }
        }
    }

    # ---- secrets: HARD blocks; WARN is advisory with rule ids (D-13)
    my (%warn);
    my @texts = ([ 'body.md', $body ], (map { [ "restart/$_", $in->{recipes}{$_} ] } sort keys %{ $in->{recipes} || {} }),
                 (map { [ $_, $in->{extra}{$_} ] } sort keys %{ $in->{extra} || {} }));
    for my $t (@texts) {
        my $hits = skills::core::secrets_scan($t->[1]);
        my %hard = map { $_->{rule} => 1 } grep { $_->{class} eq 'HARD' } @$hits;
        $warn{ $_->{rule} } = 1 for grep { $_->{class} ne 'HARD' } @$hits;
        push @block, [ 'secret-hard', "$t->[0] rules=" . join(',', sort keys %hard) ] if %hard;
    }

    # ---- advisories
    push @adv, [ 'size', length($body) . ' B' ] if length($body) > 20480;
    my $caps = skills::spec::section_caps();
    for my $name (sort keys %$caps) {
        my $s = $by_name{$name} or next;
        my $chars = 0;
        $chars += _chars($_->[1]) + 1 for @{ $s->{body} };
        push @adv, [ 'section-cap', "$name $chars>$caps->{$name}" ] if $chars > $caps->{$name};
    }
    my ($fence, $fl, $fc) = (0, 0, 0);
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A\s*```/) {
            if ($fence) { push @adv, [ 'code-block', "line $fl" ] if $fc > 5; $fence = 0 }
            else { ($fence, $fl, $fc) = (1, $i + 1, 0) }
            next;
        }
        $fc++ if $fence;
    }
    my @loglike = grep {
        $lines[$_] =~ /\A\s*(?:at\s+[\w.\$<>]+\s*\(|Traceback \(most recent call last\)|File "[^"]+", line \d+|\S+\.\w{1,4}:\d+:in\b|\[?(?:ERROR|WARN(?:ING)?|FATAL|DEBUG|INFO|TRACE)\]?[: ]|\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d[.,]\d+)/
    } 0 .. $#lines;
    push @adv, [ 'log-lines', 'line ' . ($loglike[0] + 1) . ' n=' . scalar(@loglike) ] if @loglike;
    my $run = 0;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A\s*(?:[-*]\s+)?[0-9a-f]{7,40}\b/) {
            $run++;
            push @adv, [ 'hash-lines', 'line ' . ($i - 2) ] if $run == 4;
        } else { $run = 0 }
    }
    my ($wd_name) = grep { /\AWork done/ } map { $_->{name} } @$mains;
    if ($wd_name && (my $wd = $by_name{$wd_name})) {
        my ($chg, $mr) = (_items($wd, qr/Changes\b/), _items($wd, qr/Must read\b/));
        push @adv, [ 'changes', "n=$chg" ] if $chg > 15;
        push @adv, [ 'must-read', "n=$mr" ] if $mr > 3;
    }
    push @adv, [ 'secret-warn', 'rules=' . join(',', sort keys %warn) ] if %warn;
    if (defined $in->{previous}) {
        my %pl = map { _norm($_) => 1 } grep { _counts($_) } split /\n/, $in->{previous};
        my @mine = grep { _counts($_) } @lines;
        if (@mine) {
            my $shared = grep { $pl{ _norm($_) } } @mine;
            push @adv, [ 'overlap', sprintf('%d%%', int(100 * $shared / @mine)) ] if $shared / @mine >= 0.30;
        }
    }
    return { blocking => \@block, advisory => \@adv };
}

sub _trim_path { my ($p) = @_; $p =~ s/[.:]+\z//; return $p }

sub _covered {
    my ($p, $cov) = @_;
    return 1 if $cov->{$p};
    for my $c (keys %$cov) {
        return 1 if index($c, "$p/") == 0 || index($p, "$c/") == 0;
    }
    return 0;
}

sub _chars { my ($s) = @_; my $n = () = $s =~ /[\x00-\x7f\xc0-\xff]/g; return $n }

sub _norm { my ($l) = @_; $l =~ s/\s+/ /g; $l =~ s/\A | \z//g; return $l }

# Lines that count for the overlap advisory (RV-30): not blank, not a
# heading, not a ledger line, not a fixed none-form, not a pasted Evidence
# line, not a table separator.
my $NONE;
sub _counts {
    my ($l) = @_;
    return 0 unless $l =~ /\S/;
    return 0 if $l =~ /\A#/;
    return 0 if $l =~ /\A\s*(?:[-*]\s+)?(?:[UDXQ]-\d+|Superseded:)/;
    return 0 if $l =~ /\A\s*(?:[-*]\s+)?(?:Evidence|Disposable|Ref-only|Volatile):/;
    return 0 if $l =~ /\A\s*\|\s*:?-{2,}/;
    $NONE //= (eval { skills::spec::none_res() } || []);
    my $n = _norm($l);
    return 0 if grep { $n =~ $_ } @$NONE;
    return 1;
}

# Items of a "- Changes …" or "- Must read …" entry: backticked spans or
# comma-separated items on its line plus indented continuation lines.
sub _items {
    my ($sec, $re) = @_;
    my $n = 0;
    my $on = 0;
    for my $r (@{ $sec->{body} }) {
        my $l = $r->[1];
        if ($l =~ /\A[-*]\s+(.*)\z/) {
            my $t = $1;
            $on = $t =~ /\A$re/ ? 1 : 0;
            next unless $on;
            $t =~ s/\A[^:]*:\s*//;
            my $bt = () = $t =~ /`[^`]+`/g;
            $n += $bt || scalar(grep { /\S/ } split /;/, $t);
            next;
        }
        next unless $on;
        if ($l =~ /\A\s+[-*]\s+\S/) { $n++ } elsif ($l !~ /\S/) { next } else { $on = 0 }
    }
    return $n;
}

1;

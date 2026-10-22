package skills::lint;
# lib/skills/lint.pm: the publish lint of TPL §7. It flags and never edits.
# Headings, the marker grammar, id_range_re, time_re, claim_tags.verified_re
# and the clutter classes come from assets/handoff-spec.json (BUILD-PLAN §3.4);
# the secret rules from the core secrets seam.
#
# lint(\%in) → {blocking => [[rule, where]…], advisory => [[rule, where]…]}
# %in: body, recipes {name => text}, extra {name => text} (ledger, inflight),
#      previous (text of previous_handoff, the carry base, or undef), times {shown => 1},
#      evidence [rows], bucket, brand; 2026-10-21 rulings:
#      previous_kind (own|chain|foreign) and own_previous (text of own_previous_handoff)
#        for carry-provenance and carry-approval (small-rulings §2.4) and the
#        carried-stamp exemption (CR-F29);
#      repo_mode and export_text (the body after the D-12 §1.5.5 rewrite) for
#        private-path (repo mode only);
#      jobs {task id => Dev-1 job row} for the recipe-mismatch advisory (Dev-1 D2);
#      2026-10-22 (T-TEXT E6): acuity_floor (the stage meta's) for the acuity advisory.
# The result also carries `acuity`: the rating found in Resume here, or undef.
# Every id it prints is one of the spec's lint_ids; time_re, the carry tag and the
# private-path classes come from the spec too (fail closed: spec-missing <key>).
use strict;
use warnings;
use utf8;
use skills::util;
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
    skills::spec::need(qw(time_re claim_tags.verified_re carry.tag_re carry.foreign_approval_note lint_ids private_path_classes));
    # Lines carried byte-identical from the base or from the own chain's file.
    my %prev_lines = map { $_ => 1 } split /\n/, join("\n", grep { defined } $in->{previous}, $in->{own_previous});
    # CR-F29 (DP-27): tagged ledger lines carried from a foreign base keep the base's
    # checked/verified stamps verbatim; their times are not checked.
    my $carried = _foreign_carried($in, \@lines);
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
            || ($b ne '' && (index($l, "\x{27ea}$b v1 ") >= 0 || index($l, "\x{27ea}/$b n=") >= 0));
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
            $s1 =~ s/\s+\x{2014}\s+for\b.*\z//;
            $s1 =~ s/\s*\|?\s*proposed\s*\z//;
            $s1 =~ s/\A\s+|\s+\z//g;
        }
        if (defined $n1) {
            $n1 =~ s/\s+\x{2014}\s+done when\b.*\z//;
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

    # ---- checked / verified times only from the helper. The time is the spec's
    # time_re after `checked`, or inside a claim_tags.verified_re tag.
    my $times = $in->{times} || {};
    my ($tre, $vre) = (skills::spec::time_re(), skills::spec::verified_re());
    my $checked = $tre ? qr/\bchecked[ \t]+($tre)(?![0-9])/ : undef;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next if $prev_lines{$l} || $carried->{$i};
        my @t;
        if ($checked) { while ($l =~ /$checked/g) { push @t, $1 } }
        if ($vre && $tre) {
            while ($l =~ /$vre/g) {
                my $tag = substr($l, $-[0], $+[0] - $-[0]);
                push @t, $1 if $tag =~ /($tre)/;
            }
        }
        push @block, [ 'unprinted-time', 'line ' . ($i + 1) ] for grep { !$times->{$_} } @t;
    }

    # ---- time-format (RV-24): `checked` or `[verified` with a time that is not a full
    # stamp (HH:MM, MM-DD HH:MM, a date without its offset), outside carried lines.
    # Without it a short form would slip past unprinted-time, which reads only stamps.
    my $short = qr/(?:[0-9]{4}-[0-9]{2}-[0-9]{2}[ T])?(?:[0-9]{2}-[0-9]{2} )?[0-9]{1,2}:[0-9]{2}/;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next if $prev_lines{$l} || $carried->{$i};
        my $bad = 0;
        while ($l =~ /(?:\bchecked|\[verified)[ \t]+/g) {
            my $at = substr($l, pos($l));
            next if $tre && $at =~ /\A$tre(?![0-9])/;
            $bad = 1 if $at =~ /\A$short(?![0-9])/;
        }
        push @block, [ 'time-format', 'line ' . ($i + 1) ] if $bad;
    }

    # ---- carry provenance (small-rulings §2.4): with a foreign base, a U-/D-/X- line whose
    # content is the foreign base's and not the own chain's needs a `[from …]` tag; a
    # tagged approval is context only. Reworded lines are not detected (stated limit).
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my $note = skills::spec::get('carry.foreign_approval_note');
    if (($in->{previous_kind} // '') eq 'foreign' && defined $in->{previous}) {
        my %foreign = map { my $n = _ledger_norm($_, $tag_re); defined $n ? ($n => 1) : () } split /\n/, $in->{previous};
        my %own = map { my $n = _ledger_norm($_, $tag_re); defined $n ? ($n => 1) : () } split /\n/, ($in->{own_previous} // '');
        for my $i (0 .. $#lines) {
            my $n = _ledger_norm($lines[$i], $tag_re) // next;
            next if $tag_re && $lines[$i] =~ $tag_re;
            push @block, [ 'carry-provenance', 'line ' . ($i + 1) ] if $foreign{$n} && !$own{$n};
        }
    }
    if ($tag_re) {
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next unless $l =~ $tag_re && $l =~ /\bU-[0-9]+:\s*approval\b/;
            push @block, [ 'carry-approval', 'line ' . ($i + 1) ]
                if index($l, $note) < 0 || $l =~ /\bnot yet used\b|\bused\b/;
        }
    }

    # ---- private-path (D-12 Block F; repo mode only): a machine-private path left in the
    # text the export would write after its rewrite (own home already ~/). A durable copy
    # or a Volatile: line does not excuse it: the path would reach git.
    if ($in->{repo_mode}) {
        my @x = split /\n/, ($in->{export_text} // $body), -1;
        my $classes = skills::spec::private_path_classes();
        for my $i (0 .. $#x) {
            my @ids = map { $_->{id} } grep { $x[$i] =~ $_->{re} } @$classes;
            push @block, [ 'private-path', 'line ' . ($i + 1) . ' ' . join(',', @ids) ] if @ids;
        }
    }

    # ---- id ranges (the spec's id_range_re)
    if (my $idr = skills::spec::id_range_re()) {
        for my $i (0 .. $#lines) {
            push @block, [ 'id-range', 'line ' . ($i + 1) ] if $lines[$i] =~ $idr;
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
    my $size = skills::util::blen($body);
    push @adv, [ 'size', "$size B" ] if $size > 20480;
    my $caps = skills::spec::section_caps();
    for my $name (sort keys %$caps) {
        my $s = $by_name{$name} or next;
        my $chars = 0;
        $chars += _chars($_->[1]) + 1 for @{ $s->{body} };
        push @adv, [ 'section-cap', "## $name $chars>$caps->{$name}" ] if $chars > $caps->{$name};
    }
    # store-path (PKG-RUNTIME A.4): a body line naming the launcher by its path; handoffs
    # write the symbolic `<store>` (the path changes with each plugin update and names the
    # home folder). On with a spec that lists the id (T-TEXT E2).
    if ($b ne '' && skills::spec::lint_ids()->{advisory}{'store-path'}) {
        my $sp = "/scripts/$b-store";
        for my $i (0 .. $#lines) {
            push @adv, [ 'store-path', 'line ' . ($i + 1) ] if index($lines[$i], $sp) >= 0;
        }
    }
    # Acuity (T-TEXT E6): the writer's rating in Resume here (the spec's acuity_re) against the
    # floor `begin` measured (acuity_floor in the stage meta): missing, or below the floor. A
    # spec without acuity_re (older than T-TEXT E2) has no such check.
    my $acuity;
    if (my $are = skills::spec::acuity_re()) {
        for my $r (@{ $rh ? $rh->{body} : [] }) { if ($r->[1] =~ $are) { $acuity = $1; last } }
        my @w = @{ skills::spec::acuity_words() };
        my %rank = map { $w[$_] => $_ } 0 .. $#w;
        my $floor = $in->{acuity_floor};
        if (!defined $acuity) { push @adv, [ 'acuity', 'missing' ] }
        elsif (defined $floor && defined $rank{$floor} && defined $rank{$acuity} && $rank{$acuity} < $rank{$floor}) {
            push @adv, [ 'acuity', "below $floor" ];
        }
    }
    # Clutter classes from the spec block (WATCHER M-13): code-block (max_lines),
    # log-line and stack-line, hash-run (min_run).
    my $cb = skills::spec::clutter_class('code-block');
    if ($cb && defined $cb->{max_lines}) {
        my ($fence, $fl, $fc) = (0, 0, 0);
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ $cb->{re}) {
                if ($fence) { push @adv, [ 'code-block', "line $fl" ] if $fc > $cb->{max_lines}; $fence = 0 }
                else { ($fence, $fl, $fc) = (1, $i + 1, 0) }
                next;
            }
            $fc++ if $fence;
        }
    }
    my @logcl = grep { defined } map { skills::spec::clutter_class($_) } qw(log-line stack-line);
    my @loglike = grep { my $l = $lines[$_]; grep { $l =~ $_->{re} } @logcl } 0 .. $#lines;
    push @adv, [ 'log-lines', 'line ' . ($loglike[0] + 1) . ' n=' . scalar(@loglike) ] if @loglike;
    my $hr = skills::spec::clutter_class('hash-run');
    if ($hr && $hr->{min_run}) {
        my $run = 0;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ $hr->{re}) {
                $run++;
                push @adv, [ 'hash-lines', 'line ' . ($i + 2 - $run) ] if $run == $hr->{min_run};
            } else { $run = 0 }
        }
    }
    my ($wd_name) = grep { /\AWork done/ } map { $_->{name} } @$mains;
    if ($wd_name && (my $wd = $by_name{$wd_name})) {
        my ($chg, $mr) = (_items($wd, qr/Changes\b/), _items($wd, qr/Must read\b/));
        push @adv, [ 'changes', "n=$chg" ] if $chg > 15;
        push @adv, [ 'must-read', "n=$mr" ] if $mr > 3;
    }
    push @adv, [ 'secret-warn', 'rules=' . join(',', sort keys %warn) ] if %warn;
    # Dev-1 D2: a recipe whose command: differs from the plugin's job record of its task.
    for my $name (sort keys %{ $in->{recipes} || {} }) {
        my $t = $in->{recipes}{$name};
        my ($rid) = $t =~ /^\s*item:\s*B-\d+.*?runtime id\s+([A-Za-z0-9._:-]+)/m;
        my $job = defined $rid ? ($in->{jobs} || {})->{$rid} : undef;
        next unless $job && defined $job->{command};
        my ($cmd) = $t =~ /^\s*command:[ \t]*(.*?)[ \t]*$/m;
        push @adv, [ 'recipe-mismatch', "restart/$name" ] if !defined $cmd || $cmd ne skills::core::recipe_command($job->{command});
    }
    if (defined $in->{previous}) {
        my %pl = map { _norm($_) => 1 } grep { _counts($_) } split /\n/, $in->{previous};
        my @mine = grep { _counts($_) } @lines;
        if (@mine) {
            my $shared = grep { $pl{ _norm($_) } } @mine;
            push @adv, [ 'overlap', sprintf('%d%%', int(100 * $shared / @mine)) ] if $shared / @mine >= 0.30;
        }
    }
    my $ids = skills::spec::lint_ids();
    for my $r (@block) { die "lint id $r->[0] not in the spec's lint_ids\n" unless $ids->{blocking}{ $r->[0] } }
    for my $r (@adv) { die "lint id $r->[0] not in the spec's lint_ids\n" unless $ids->{advisory}{ $r->[0] } }
    return { blocking => \@block, advisory => \@adv, acuity => $acuity };
}

# A U-, D- or X- ledger line's content with its bullet, id and carry tags removed and
# white space collapsed; undef for any other line.
sub _ledger_norm {
    my ($l, $tag_re) = @_;
    return undef unless $l =~ /\A\s*(?:[-*]\s+)?[UDX]-[0-9]+:\s*(.*)\z/;
    my $c = $1;
    $c =~ s/$tag_re//g if $tag_re;
    $c =~ s/\s+/ /g;
    $c =~ s/\A | \z//g;
    return $c eq '' ? undef : $c;
}

# {line index => 1} for body lines carried from a foreign base (CR-F29, DP-27): a line
# with a `[from …]` tag whose _ledger_norm (no leading id, no tags, spacing folded) equals
# a base line's. Its stamps are then the base's own; any tag counts, since a base line
# that already had a tag keeps that tag (template rule 8).
sub _foreign_carried {
    my ($in, $lines) = @_;
    my %c;
    return \%c unless ($in->{previous_kind} // '') eq 'foreign' && defined $in->{previous};
    my $tag_re = skills::spec::regex_at('carry.tag_re') or return \%c;
    my %base = map { my $n = _ledger_norm($_, $tag_re); defined $n ? ($n => 1) : () } split /\n/, $in->{previous};
    for my $i (0 .. $#$lines) {
        next unless $lines->[$i] =~ $tag_re;
        my $n = _ledger_norm($lines->[$i], $tag_re);
        $c{$i} = 1 if defined $n && $base{$n};
    }
    return \%c;
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

# Characters of a line (text is characters, P5-FOLD A4).
sub _chars { my ($s) = @_; return length skills::util::text($s) }

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

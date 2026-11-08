package skills::lint;
# lib/skills/lint.pm: the publish lint of TPL §7. lint() flags and never edits; fix() (0.1.5, E-3)
# writes the mechanical blocking ones into a copy of the body for publish (see there).
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
#      2026-10-22 (T-TEXT E6): acuity_floor (the stage meta's) for the acuity advisory;
#      (Q-ADAPTER QA-4) queue_mode (the stage meta's: off|on|degraded) for queue-off;
#      2026-10-23 (AP-4): approval_chain [{text, checked}] (the own chain's file),
#        transcript (the writing session's transcript path, undef when not found) and
#        session_id (rows of another session do not count) for the approval checks
#        (skills::approvals); quote_floor [ok, epoch] (skills::approvals::quote_floor: a
#        claimed session counts only rows after the claim).
#      0.1.2 (D-8): approval_context_only (a stage bound to a plugin handoff turn): every own
#        approval must be the context-only form (approval-plugin-turn).
#      0.1.3: carried_as {line => draft line} (publish's re-lint after moving approvals: a line
#        whose draft text was carried stays carried; 0.1.5: after skills::lint::fix too, from the
#        base and from a foreign base alike; a text two draft lines became, [draft lines]: carried
#        only when each is).
#      0.1.5 (E-1, stable ledger): ledger_base (the own chain's previous file: the carry base when
#        it is own or chain, own_previous with a foreign base; undef without one) for
#        ledger-id-reuse, ledger-changed and ledger-carried (lib/ledger.pm); export_fn (repo
#        mode: text -> its export) for the private-path check of the carried lines.
# The result also carries `acuity`: the rating found in Resume here, or undef; `ledger`: the
# ledger::check result publish carries the dropped lines with; and
# `approvals`: {checked => [U-n…], lines, unchecked, classes, origins} for the frontmatter, the row
# and the line-hash record.
# Every id it prints is one of the spec's lint_ids; time_re, the carry tag and the
# private-path classes come from the spec too (fail closed: spec-missing <key>).
use strict;
use warnings;
use utf8;
use skills::util;
use skills::spec;
use skills::core;
use skills::approvals;

# The most line numbers `ADVISORY secret-warn` names (0.1.3); the rest are counted as +<n>.
our $WARN_LINES_MAX = 10;

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
    # carried_as {line => draft line}: publish rewrote a moved approval's id in these lines
    # (skills::approvals::move_lines); one whose draft text was carried is still carried.
    my $cas = ref $in->{carried_as} eq 'HASH' ? $in->{carried_as} : {};
    $prev_lines{$_} = 1 for grep { my @d = _draft_texts($cas, $_); @d && !grep { !$prev_lines{$_} } @d } keys %$cas;
    # CR-F29 (DP-27): tagged ledger lines carried from a foreign base keep the base's
    # checked/verified stamps verbatim; their times are not checked (a fixed line: its draft's).
    my $carried = _foreign_carried($in, \@lines, $cas);
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
        push @block, [ 'step1-mismatch', "line $rh->{line}" ] unless _step1_same($s1, $n1);
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
                next if $volatile{$p} || _covered($p, \%covered) || _test_exempt($p);
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
    # A line publish rewrote (carried_as) is read as its draft text(s) too (0.1.5 review: a copied
    # line whose range fix() listed no longer equalled the base's and went out untagged).
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my $note = skills::spec::get('carry.foreign_approval_note');
    if (($in->{previous_kind} // '') eq 'foreign' && defined $in->{previous}) {
        my %foreign = map { my $n = _ledger_norm($_, $tag_re); defined $n ? ($n => 1) : () } split /\n/, $in->{previous};
        my %own = map { my $n = _ledger_norm($_, $tag_re); defined $n ? ($n => 1) : () } split /\n/, ($in->{own_previous} // '');
        for my $i (0 .. $#lines) {
            next if $tag_re && $lines[$i] =~ $tag_re;
            my @n = grep { defined } map { _ledger_norm($_, $tag_re) } $lines[$i], _draft_texts($cas, $lines[$i]);
            push @block, [ 'carry-provenance', 'line ' . ($i + 1) ] if grep { $foreign{$_} && !$own{$_} } @n;
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

    # ---- scoped approvals (AP-4; spec §15): approval-shape, approval-quote (own untagged
    # lines: carried from an own-chain file that listed the id, else the quote in this
    # session's human-typed rows), approval-unchecked (transcript unreadable). On with a spec
    # that has the section and the three ids.
    my $approvals = skills::approvals::lint(\@lines, prev_lines => \%prev_lines, tag_re => $tag_re, note => $note,
                                            chain => $in->{approval_chain}, transcript => $in->{transcript},
                                            sid => $in->{session_id}, quote_floor => $in->{quote_floor},
                                            context_only => $in->{approval_context_only});
    push @block, @{ $approvals->{blocking} };
    push @adv, @{ $approvals->{advisory} };

    # ---- the stable ledger (0.1.5 E-1, spec §7): against the own chain's previous file, an id the
    # draft gives to another item blocks (ids stay unique across a chain); a ledger line whose text
    # changed is advisory; the ledger lines the draft dropped without a Superseded line are named,
    # and publish copies them back when it writes the file.
    my $ledger = skills::core::ledger_check($in->{ledger_base}, $body);
    push @block, [ 'ledger-id-reuse', "line $_->[1] $_->[0]" ] for @{ $ledger->{reused} };
    push @adv, [ 'ledger-changed', "line $_->[1] $_->[0]" ] for @{ $ledger->{changed} };
    push @adv, [ 'ledger-carried', join(', ', @{ $ledger->{ids} }) ] if @{ $ledger->{ids} };
    # The carried lines reach the written file and its export, so they pass the private-path and
    # secret checks too (a file published before repo mode was on may hold a private path); a hit
    # names the line `carried <id>` by the first id it carries, as ledger-carried names it (a foreign
    # pointer line's `<sid8>:D-1`): writing the line, fixed, into the draft keeps it from carrying.
    my @carried = map { $_->[0] } @{ $ledger->{carry} || [] };
    my %cid = map { ($_->[0] => ($_->[2] || [])->[0]) } @{ $ledger->{carry} || [] };
    my $cname = sub { 'carried ' . ($cid{ $_[0] } // 'line') };

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
        for my $l (@carried) {
            my $x = $in->{export_fn} ? $in->{export_fn}->($l) : $l;
            my @ids = map { $_->{id} } grep { $x =~ $_->{re} } @$classes;
            push @block, [ 'private-path', $cname->($l) . ' ' . join(',', @ids) ] if @ids;
        }
    }

    # ---- id ranges (the spec's id_range_re). 0.1.2 handoff-lint: a range blocks
    # - on a ledger pointer line (one naming ledger.md or inflight.md, which lists each moved id,
    #   or §7's fold line `D-1, X-2 settled; full text in <path>`);
    # - when it covers a chain id (one a ledger line or table row of the draft itself, the base,
    #   the own previous file or the stage's ledger.md / inflight.md defines) that the draft never
    #   names alone;
    # - when it leads the line (the line's first ids, after a bullet, a list number, a table bar
    #   or bold marks) and one of its ids is never named alone, if the line is ledger-shaped (the
    #   ids end in `:`, `|` or ` · `, or end the line: `- D-1..D-6: settled`, `| B-1..B-2 | …`)
    #   or the range covers a chain id (`D-1..D-3 settled` under `- D-1: …`, `- D-2: …`).
    # A range of ids the chain never defines (another register's D-1255..D-1268, also leading a
    # line of prose), one reaching past chain ids the draft names alone (`- D-1289: register
    # rows D-1289..D-1301 …`) and a summary of ids the draft lists one by one (the B- rows of the
    # In flight table) lose no id. Ids compare without leading zeros (D-01 is D-1).
    if (my $idr = skills::spec::id_range_re()) {
        # Read through exists: a slice of $in->{extra} would create the keys, and publish files
        # every key of extra into evidence/.
        my $ex = $in->{extra} || {};
        my $chain = _defined_ids(join "\n", grep { defined } $body, $in->{previous}, $in->{own_previous},
                                 map { exists $ex->{$_} ? $ex->{$_} : undef } qw(ledger.md inflight.md));
        my $alone = _alone_ids($body, $idr);
        my $tok = qr/(?:$idr|\b[UDXQB]-[0-9]+\b)/;
        my $mk = qr/[*_`]*/;
        my $lead_re = qr/\A\s*(?:[-*+]\s+|[0-9]+[.)]\s+|\|\s*)?$mk$tok(?:$mk\s*(?:,|\band\b)\s*$mk$tok)*$mk/;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            my ($lead_end, $shaped) = (-1, 0);
            if ($l =~ $lead_re) {
                $lead_end = $+[0];
                $shaped = substr($l, $lead_end) =~ /\A\s*(?:[:|\x{b7}]|\z)/ ? 1 : 0;
            }
            my $hit = 0;
            while (!$hit && $l =~ /($idr)/g) {
                my ($r, $lead) = ($1, $-[1] < $lead_end);
                my $ids = _range_ids($r);
                $hit = 1 if !$ids || $l =~ /\b(?:ledger|inflight)\.md\b|;\s*full text in\b/;
                next if $hit;
                my @unnamed = grep { !$alone->{$_} } @$ids;
                my $touch = grep { $chain->{$_} } @$ids;
                $hit = 1 if grep { $chain->{$_} } @unnamed;
                $hit = 1 if $lead && @unnamed && ($shaped || $touch);
            }
            push @block, [ 'id-range', 'line ' . ($i + 1) ] if $hit;
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
                if _placeholder($l) || $l =~ /\b(?:TODO|TBD|FIXME)\b/;
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

    # ---- queue-off (Q-ADAPTER QA-4): with no queue configured (begin measured mode off),
    # nothing was queued: a typed `Queued:` line anywhere, or a `· queued` mark on an Open
    # questions row, blocks. On with a spec that lists the id (T-TEXT E2).
    if (($in->{queue_mode} // '') eq 'off' && skills::spec::lint_ids()->{blocking}{'queue-off'}) {
        for my $i (0 .. $#lines) {
            push @block, [ 'queue-off', 'line ' . ($i + 1) ] if $lines[$i] =~ /\A[\s>|*-]*Queued:/;
        }
        my ($oq) = grep { /\AOpen questions/ } map { $_->{name} } @$mains;
        my $qs = $oq ? $by_name{$oq} : undef;
        for my $r (@{ $qs ? $qs->{body} : [] }) {
            next if $r->[1] =~ /\A[\s>|*-]*Queued:/;
            push @block, [ 'queue-off', "line $r->[0]" ] if $r->[1] =~ /·\s*queued\b/;
        }
    }

    # ---- secrets: HARD blocks; WARN is advisory with rule ids (D-13)
    # 0.1.3: a WARN hit names its line numbers too (body.md's bare, another file's as <file>:<n>)
    my (%warn, @warn_at);
    my @texts = ([ 'body.md', $body ], (map { [ "restart/$_", $in->{recipes}{$_} ] } sort keys %{ $in->{recipes} || {} }),
                 (map { [ $_, $in->{extra}{$_} ] } sort keys %{ $in->{extra} || {} }),
                 (map { [ $cname->($_), $_ ] } @carried));
    for my $t (@texts) {
        my $hits = skills::core::secrets_scan($t->[1], lines => 1);
        my %hard = map { $_->{rule} => 1 } grep { $_->{class} eq 'HARD' } @$hits;
        my @w = grep { $_->{class} ne 'HARD' } @$hits;
        @w = () if $t->[0] =~ /\Acarried /;   # a carried line warned when it was published
        $warn{ $_->{rule} } = 1 for @w;
        my %ln = map { $_ => 1 } map { @{ $_->{lines} || [] } } @w;
        push @warn_at, map { $t->[0] eq 'body.md' ? $_ : "$t->[0]:$_" } _by_number(keys %ln);
        push @block, [ 'secret-hard', "$t->[0] rules=" . join(',', sort keys %hard) ] if %hard;
    }

    # ---- advisories
    my $size = skills::util::blen($body);
    push @adv, [ 'size', "$size B" ] if $size > 20480;
    # In Evidence only the model's own lines count (0.1.2 handoff-lint): the lines the helper
    # pasted (_helper_pasted) are its text, not a choice to cut.
    my $caps = skills::spec::section_caps();
    for my $name (sort keys %$caps) {
        my $s = $by_name{$name} or next;
        my $chars = 0;
        my $skip = $name =~ /\AEvidence\b/;
        $chars += _chars($_->[1]) + 1 for grep { !($skip && _helper_pasted($_->[1])) } @{ $s->{body} };
        push @adv, [ 'section-cap', "## $name $chars>$caps->{$name}" ] if $chars > $caps->{$name};
    }
    # store-path (PKG-RUNTIME A.4): a body line naming the launcher by its path; handoffs
    # write the symbolic `<store>` (the path changes with each plugin update and names the
    # home folder). On with a spec that lists the id (T-TEXT E2).
    if ($b ne '' && skills::spec::lint_ids()->{advisory}{'store-path'}) {
        my $sp = '/scripts/' . $b . '-store';
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
    if (%warn) {
        my @at = @warn_at > $WARN_LINES_MAX ? (@warn_at[0 .. $WARN_LINES_MAX - 1], '+' . (@warn_at - $WARN_LINES_MAX)) : @warn_at;
        push @adv, [ 'secret-warn', 'rules=' . join(',', sort keys %warn) . (@at ? ' lines=' . join(',', @at) : '') ];
    }
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
    return { blocking => \@block, advisory => \@adv, acuity => $acuity, approvals => $approvals, ledger => $ledger };
}

# The most ids fix() writes for one id range; a longer range is left as written (and blocks).
our $FIX_RANGE_MAX = 50;

# fix($body, $blocking) (0.1.5, E-3: the usage review counted 14 drafts refused for id ranges,
# each round a Write and a publish): the blocking entries of lint() that are mechanical, written
# into a copy of the body.
# - id-range: on a flagged line every range is written as its ids (`U-1..U-3` as `U-1, U-2, U-3`;
#   a zero-padded start keeps its width), when each range there is one _range_ids reads, it
#   covers at most $FIX_RANGE_MAX ids and none is in quotes (double, or single ones that open
#   and close outside a word), a code span, a fenced or indented code block, an argument after
#   `=` or a file name or path (_list_ranges; review: a rewritten quote lost a real approval,
#   and a rewritten command changed its arguments); otherwise the line stays as written (and
#   blocks). An approval line (in `## Approvals`, or any `U-<n>: approval` line) is never
#   rewritten (review: its action and targets are compared with the own chain's file, so a
#   carried approval stopped being carried); a range there that still blocks once the other
#   lines are listed stays a LINT line.
#   Step 1 and Next steps item 1 that matched still match: when one of them is rewritten the
#   other is rewritten the same way, or, when that cannot be done, neither is.
# - step1-mismatch: when Next steps has no item 1 (no line starting `1.` or `1)`), Step 1's text
#   (the first `Step 1:` line, as lint() reads it; an empty one adds nothing) goes in as item 1,
#   before the section's first list line outside a code block (after its text when it has none;
#   none when that place is inside a fence left open); an item 1 that differs stays. The added
#   line counts as carried when Step 1 does.
# Returns {body, fixes => [{rule, line, text}…] (line: the body line it changed, Step 1's for an
# added item), map => {fixed body line => body line; the added item reads as the Next steps
# heading's line, so a finding on it is told apart from one on Step 1},
# was => {fixed line text => line text, or [line texts] when more than one line has that text
# now (lint carried_as: carried only when each is)}}.
sub fix {
    my ($body, $blocking) = @_;
    my @lines = split /\n/, $body // '', -1;
    my (%at, @fixes, %was, %fx);
    for my $e (@{ $blocking || [] }) {
        push @{ $at{ $e->[0] } }, $1 if ($e->[1] // '') =~ /\Aline ([0-9]+)\z/;
    }
    my $idr = $at{'id-range'} ? skills::spec::id_range_re() : undef;
    # Lines left as written: a fenced or an indented code block (4 spaces or a tab, not a list
    # item) and an approval line.
    # %code: the code lines alone; %open: a fence is open after that line. Fences as move_lines
    # reads them (skills::approvals::fence_lines, CommonMark's closing rule).
    my $fl = skills::approvals::fence_lines(\@lines);
    my %code = %{ $fl->{code} };
    my %open = %{ $fl->{open} };
    for my $i (0 .. $#lines) {
        $code{$i} = 1 if $lines[$i] =~ /\A(?: {4}|\t)/ && $lines[$i] !~ /\A\s*(?:[-*+]|[0-9]+[.)])\s/;
    }
    my %keep = (%{ skills::approvals::section_lines(\@lines) }, %code);
    $keep{$_} = 1 for grep { skills::approvals::is_approval_line($lines[$_]) } 0 .. $#lines;
    my $add = sub {
        my ($new, @o) = @_;
        my %u = map { $_ => 1 } _draft_texts(\%was, $new), @o;
        my @u = sort keys %u;
        $was{$new} = @u == 1 ? $u[0] : \@u;
    };
    my $list = sub { my ($i) = @_; return $idr && defined $lines[$i] && !$keep{$i} ? _list_ranges($lines[$i], $idr) : () };
    my %seen;
    for my $n (grep { $idr && !$seen{$_}++ } @{ $at{'id-range'} || [] }) {
        my ($new, $r) = $list->($n - 1) or next;
        $fx{ $n - 1 } = [ $new, $r ];
    }
    my $mains = skills::spec::sections_main();
    my $sec = sub {
        my ($lit) = @_;
        my ($h) = grep { $lines[$_] =~ /\A##\s/ && $lines[$_] !~ /\A###/ && index($lines[$_], $lit) == 0 } 0 .. $#lines;
        return undef unless defined $h;
        my $e = $h + 1;
        $e++ while $e <= $#lines && !($lines[$e] =~ /\A##\s/ && $lines[$e] !~ /\A###/);
        return { h => $h, body => [ $h + 1 .. $e - 1 ] };
    };
    my ($rh, $ns) = @$mains ? ($sec->($mains->[0]{literal}), $sec->($mains->[-1]{literal})) : ();
    my ($si) = $rh ? grep { $lines[$_] =~ /\A\s*Step 1:/ } @{ $rh->{body} } : ();
    # Step 1 and item 1 as lint() reads them: a pair that matched keeps matching (review: only
    # item 1 led its line, so only it was flagged and rewritten, and step1-mismatch blocked).
    my ($ni) = $ns ? grep { $lines[$_] =~ /\A\s*1\.\s+/ } @{ $ns->{body} } : ();
    if (defined $si && defined $ni && ($fx{$si} || $fx{$ni})) {
        my $pair = sub {
            my ($s, $n) = @_;
            my ($s1) = $s =~ /\A\s*Step 1:\s*(.*)\z/;
            my ($n1) = $n =~ /\A\s*1\.\s+(.*)\z/;
            return _step1_same($s1, $n1);
        };
        if ($pair->($lines[$si], $lines[$ni])) {
            for my $i (grep { !$fx{$_} } $si, $ni) { my ($new, $r) = $list->($i); $fx{$i} = [ $new, $r ] if defined $new }
            my ($s, $n) = map { $fx{$_} ? $fx{$_}[0] : $lines[$_] } $si, $ni;
            delete @fx{ $si, $ni } unless $pair->($s, $n);
        }
    }
    # A text a fixed line now shares with a line left as is reads as that line's too.
    my %plain = map { ($lines[$_] => 1) } grep { !$fx{$_} } 0 .. $#lines;
    for my $i (sort { $a <=> $b } keys %fx) {
        my ($new, $r) = @{ $fx{$i} };
        $add->($new, $lines[$i]);
        $lines[$i] = $new;
        push @fixes, { rule => 'id-range', line => $i + 1, text => 'publish lists each id: ' . join('; ', @$r) };
    }
    my @org = map { $_ + 1 } 0 .. $#lines;
    if ($at{'step1-mismatch'} && defined $si && $ns && !grep { $lines[$_] =~ /\A\s*1[.)]/ } @{ $ns->{body} }) {
        my ($s1) = $lines[$si] =~ /\A\s*Step 1:\s*(.*?)\s*\z/;
        if ($s1 =~ tr/`//dr =~ /\S/) {
            # Before the first list line, so a lead-in (`In this order:`) stays above the list; a line
            # of a code block is no list line, and an item that would land in an open fence is not
            # added (review: `- old` of a diff block took the item inside the block).
            my ($li) = grep { !$code{$_} && $lines[$_] =~ /\A {0,3}(?:[-*+]|[0-9]+[.)])\s/ } @{ $ns->{body} };
            my @c = grep { $lines[$_] =~ /\S/ } @{ $ns->{body} };
            my $i = $li // (@c ? $c[-1] + 1 : $ns->{h} + 1);
            if (!$open{ $i - 1 }) {
                my @d = _draft_texts(\%was, $lines[$si]);
                $add->("1. $s1", @d ? @d : $lines[$si]);
                splice @lines, $i, 0, "1. $s1";
                splice @org, $i, 0, $ns->{h} + 1;
                push @fixes, { rule => 'step1-mismatch', line => $si + 1, text => 'Next steps has no item 1; publish adds Step 1 there as item 1' };
            }
        }
    }
    return { body => $body, fixes => [], map => {}, was => {} } unless @fixes;
    $add->($_, $_) for grep { $plain{$_} } keys %was;
    return { body => join("\n", @lines), fixes => [ sort { $a->{line} <=> $b->{line} } @fixes ],
             map => { map { ($_ + 1 => $org[$_]) } 0 .. $#org }, was => \%was };
}

# _list_ranges($line, $id_range_re) -> ($new line, ["<range> as <ids>"…]): every range on the
# line written as its ids, or () when a range there is not listable (_range_list), sits in
# quotes or a code span (the user's words, a command: the segments move_lines leaves alone, and
# single quotes that open and close outside a word, so `don't` opens none), is a command's
# argument after `=` (`--only=D-2..D-4`) or is part of a file name, a path or a longer word
# (`/` or `-` before it; `/`, `-`, or `.` and a word character after it).
sub _list_ranges {
    my ($l, $idr) = @_;
    my (@r, $bad);
    my @seg = split /("[^"]*"|\x{201c}[^\x{201d}]*\x{201d}|`[^`]*`|(?<![\w'])'[^']*'(?![\w'])|\x{2018}[^\x{2019}]*\x{2019}(?!\w))/, $l, -1;
    for my $k (0 .. $#seg) {
        if ($k % 2) { $bad = 1 if $seg[$k] =~ $idr; next }
        my $orig = $seg[$k];
        $seg[$k] =~ s{($idr)}{
            my ($r, $x0, $x1) = ($1, $-[0], $+[0]);
            my $x = _range_list($r);
            $bad = 1 if !defined $x || substr($orig, 0, $x0) =~ m{[/=-]\z} || substr($orig, $x1) =~ m{\A(?:[/-]|\.\w)};
            push @r, "$r as $x" if defined $x;
            $x // $r;
        }ge;
    }
    return () if $bad || !@r;
    my $new = join '', @seg;
    return $new eq $l ? () : ($new, \@r);
}

# The ids an id range covers as fix() writes them (`D-1, D-2, D-3`; a zero-padded start keeps its
# width: `D-01, D-02`), or undef when _range_ids reads none or they are over $FIX_RANGE_MAX.
sub _range_list {
    my ($r) = @_;
    my $ids = _range_ids($r);
    return undef unless $ids && @$ids <= $FIX_RANGE_MAX;
    my ($k, $x, $y) = $r =~ /\A([UDXQB])-([0-9]+)\D+?(?:[UDXQB]-)?([0-9]+)\z/;
    my $w = $x =~ /\A0/ ? length $x : 1;
    return join ', ', map { sprintf '%s-%0*d', $k, $w, $_ } ($x + 0) .. ($y + 0);
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
# A line publish rewrote (carried_as, $cas) is read as its draft text (0.1.5 review: a carried line
# whose range fix() listed no longer equalled the base's, so its stamp blocked as unprinted-time);
# a text two draft lines became is carried only when each is.
sub _foreign_carried {
    my ($in, $lines, $cas) = @_;
    my %c;
    return \%c unless ($in->{previous_kind} // '') eq 'foreign' && defined $in->{previous};
    my $tag_re = skills::spec::regex_at('carry.tag_re') or return \%c;
    my %base = map { my $n = _ledger_norm($_, $tag_re); defined $n ? ($n => 1) : () } split /\n/, $in->{previous};
    my $on = sub { my ($l) = @_; return 0 unless $l =~ $tag_re; my $n = _ledger_norm($l, $tag_re); return defined $n && $base{$n} ? 1 : 0 };
    for my $i (0 .. $#$lines) {
        next unless $lines->[$i] =~ $tag_re;
        my @d = _draft_texts($cas, $lines->[$i]);
        @d = ($lines->[$i]) unless @d;
        $c{$i} = 1 unless grep { !$on->($_) } @d;
    }
    return \%c;
}

# The draft texts carried_as gives a line (one, or the list when two draft lines became it), or ().
sub _draft_texts {
    my ($cas, $t) = @_;
    my $v = ref $cas eq 'HASH' ? $cas->{$t} : undef;
    return () unless defined $v;
    return ref $v eq 'ARRAY' ? @$v : ($v);
}

# numbers ascending (lint() holds a lexical $b, the brand, so it cannot sort with $a and $b itself)
sub _by_number { return sort { $a <=> $b } @_ }

sub _trim_path { my ($p) = @_; $p =~ s/[.:]+\z//; return $p }

# step1-mismatch (0.1.2 handoff-lint): Step 1 and Next steps item 1 name the same command or
# edit. Two texts that are the same (backticks and white space aside) always match. Else the
# "— for …" and "— done when …" tails and a proposed mark on either side (`| proposed`,
# `— proposed`, `as proposed`, `| as proposed`, `— as proposed` or a bare trailing
# `proposed`, each with an optional trailing `(…)` note) do not count, and the texts are equal,
# or item 1 is Step 1 followed by ` — ` and detail. A Step 1 that is one backticked command,
# alone or followed by ` — ` and detail, also matches an item 1 that is that command
# (backticks do not count), alone or followed by ` — ` and detail. Detail is
# prose: a backticked command in it (a span with white space inside, such as a second command
# riding along) blocks, while a one-word span (an identifier, a path, a file name) is prose. A
# proposed mark's `(…)` note holding such a command is compared too. Anything else after the
# command on either side (an extra argument, a glued word, other words) is compared as text,
# so it blocks unless both sides say the same. The form's marks are not the step's words: a wait
# mark (`· waits: job`, `— waits: you`, wherever it stands) and a trailing `· todo` or `· done`
# do not count (0.1.5 E-4).
sub _step1_same {
    my ($s1, $n1) = @_;
    return 0 unless defined $s1 && defined $n1;
    for my $t ($s1, $n1) { $t =~ s/\s*[·—–]\s*waits:\s*(?:job|you)\b(?!\s*[|\/])//gi; $t =~ s/\s*·\s*(?:todo|done)\s*\z//i }
    my $flat = sub { my ($t) = @_; $t =~ s/`//g; $t =~ s/\s+/ /g; $t =~ s/\A | \z//g; return $t };
    my $cmd = sub { my ($t) = @_; while ($t =~ /`([^`]*)`/g) { return 1 if $1 =~ /\S\s+\S/ } return 0 };
    return 0 if $flat->($s1) eq '';
    return 1 if $flat->($s1) eq $flat->($n1);
    $s1 =~ s/\s+\x{2014}\s+for\b.*\z//;
    $n1 =~ s/\s+\x{2014}\s+done when\b.*\z//;
    for my $t ($s1, $n1) {
        next unless $t =~ /\s*(?:(?:\||\x{2014})\s*)?(?:\bas\s+)?proposed(\s*\([^()]*\))?\s*\z/;
        my ($at, $note) = ($-[0], $1);
        next if defined $note && $cmd->($note);
        substr($t, $at) = '';
    }
    my ($fs, $fn) = ($flat->($s1), $flat->($n1));
    return 0 if $fs eq '';
    return 1 if $fs eq $fn;
    # $raw is $head (flattened), then ` — ` and detail with no backticked command.
    my $detail = sub {
        my ($raw, $head) = @_;
        while ($raw =~ /\s+\x{2014}\s+/g) {
            my ($x, $y) = ($-[0], $+[0]);
            next unless $flat->(substr($raw, 0, $x)) eq $head;
            return $cmd->(substr($raw, $y)) ? 0 : 1;
        }
        return 0;
    };
    return 1 if $detail->($n1, $fs);
    if ($s1 =~ /\A\s*`([^`]+)`/) {
        my $c = $flat->($1);
        return 1 if ($fs eq $c || $detail->($s1, $c)) && ($fn eq $c || $detail->($n1, $c));
    }
    return 0;
}

# recipe-placeholder (0.1.2 handoff-lint): a `<…>` stand-in in a recipe line, except
# - the note after `script: none`;
# - in `expected outputs:`, a value the job prints: a `<…>` right after `=` or `-`
#   (`EXIT=<n>`, `server=<pid>`, `run-<n>`) with no `/` after it; any other `<…>` there, one
#   in a path (`<scratch>/out.md`, `run-<n>/log`) and a pointer still count;
# - the words of an agent prompt after a `prompt=` / `prompt:` argument (not a CLI flag such as
#   `--prompt=`): they are the spawned agent's own text, unless the `<…>` is the whole prompt
#   value (`prompt="<the brief above>"`), a pointer or part of a path (`<scratch>/out.md`,
#   `$TMP/<name>.md`);
# - in `spawns:`, a counter `<n>` that ends an agent's label after `-` (`fix-7c-<n>`: one agent
#   per round, numbered as it starts; 0.1.5, E-3), not followed by `/`, `.`, `-` or a word
#   character (`fix-<n>-final` still counts); the label is one word of letters, digits, `_` and
#   `-` in a label place: right after `(`, `[`, `,`, `spawns:`, `agent:` or `label` (`label:`,
#   `label=`), the spec's list and no other word (review: `model claude-<n>` and `output
#   out-<n>` are stand-ins, not labels; review 5: `agents`, `labels` and a bare `agent` were
#   label places too), so the end of a path (`$TMP/run-<n>`) still counts.
# A pointer stands for text stated elsewhere: a `<…>` with a word such as above, same or that
# (`<the brief above>`, `<same path>`, `<that copy>`).
sub _placeholder {
    my ($l) = @_;
    my $ph = qr/<[A-Za-z][A-Za-z ,;:'|-]{0,80}>/;
    $l =~ s{((?:[(\[,]|\A\s*spawns:|\bagent:|\blabel\b[:=]?)[ \t]*["'`]?)([A-Za-z0-9_][A-Za-z0-9_-]*-)<n>(?![\w/.<-])}{$1$2}g if $l =~ /\A\s*spawns:/;
    my $pointer = sub {
        my ($t) = @_;
        while ($t =~ /($ph)/g) {
            return 1 if $1 =~ /\b(?:above|below|earlier|previous|prior|same|that|those|its|said|verbatim)\b/i;
        }
        return 0;
    };
    return 0 if $l =~ /\A\s*script:\s*none\b/i;
    if ($l =~ /\A\s*expected outputs:/i) {
        while ($l =~ /$ph/g) {
            my ($x, $y) = ($-[0], $+[0]);
            my $before = $x > 0 ? substr($l, $x - 1, 1) : '';
            my $after = $y < length($l) ? substr($l, $y, 1) : '';
            return 1 if ($before ne '=' && $before ne '-') || $after eq q{/} || $pointer->(substr($l, $x, $y - $x));
        }
        return 0;
    }
    if ($l =~ /(?<![-\w])prompt\s*[=:]\s*["'`]?/g) {
        my $at = pos($l);
        my $tail = substr($l, $at);
        return 1 if $tail =~ /\A$ph["'`]?\s*(?:[),;]|\z)/ || $pointer->($tail) || $tail =~ m{$ph/|/$ph};
        return substr($l, 0, $at) =~ $ph ? 1 : 0;
    }
    return $l =~ $ph ? 1 : 0;
}

# An id without leading zeros in its number (D-01 is D-1).
sub _idn { my ($k, $n) = @_; return $k . '-' . ($n + 0) }

# {id => 1} for the ids a ledger line (`- U-3: …`) or a table row (`| Q-2 | …`, `| B-1 · …`)
# defines, and every id on a ledger pointer line (one naming ledger.md).
sub _defined_ids {
    my ($t) = @_;
    my %d;
    for my $l (split /\n/, $t // '') {
        if ($l =~ /\A\s*(?:[-*]\s+)?([UDX])-([0-9]+):/ || $l =~ /\A\s*\|\s*([QB])-([0-9]+)\b/) { $d{ _idn($1, $2) } = 1 }
        if ($l =~ /\bledger\.md\b/) { $d{ _idn($1, $2) } = 1 while $l =~ /\b([UDXQB])-([0-9]+)\b/g }
    }
    return \%d;
}

# {id => 1} for the ids the text names by themselves, outside any id range.
sub _alone_ids {
    my ($t, $idr) = @_;
    $t =~ s/$idr/ /g;
    my %got;
    $got{ _idn($1, $2) } = 1 while $t =~ /\b([UDXQB])-([0-9]+)\b/g;
    return \%got;
}

# The ids an id range covers ([U-1, U-2, U-3] for `U-1..U-3`), or undef when the two ends
# differ in kind, run backwards or span more than 1000 ids (such a range always blocks).
sub _range_ids {
    my ($r) = @_;
    my ($k, $x, $k2, $y) = $r =~ /\A([UDXQB])-([0-9]+)\D+?(?:([UDXQB])-)?([0-9]+)\z/ or return undef;
    return undef if (defined $k2 && $k2 ne $k) || $y < $x || $y - $x > 1000;
    return [ map { _idn($k, $_) } $x .. $y ];
}

# Test seam (STORE_TEST_MODE only): STORE_TEST_EPHEMERAL_EXEMPT=<folder> (absolute) makes a path at
# or under that folder not ephemeral. The case runner sets it to a repo-based case's work folder
# (tmp_base "repo", under the repo's tmp/), so a checkout under /tmp still runs those cases; every
# other path under a temp root stays ephemeral, and the temp-root list is unchanged. macOS's
# /private/tmp and /private/var are compared as /tmp and /var, the names the list holds for them.
sub _test_exempt {
    my ($p) = @_;
    return 0 unless skills::util::test_mode();
    my $x = $ENV{STORE_TEST_EPHEMERAL_EXEMPT} // '';
    return 0 unless $x =~ m{\A/[^/]} && $x !~ m{(?:\A|/)\.\.?(?:/|\z)};
    my @f = map { (my $f = $_) =~ s{\A/private(?=/(?:tmp|var)/)}{}; $f =~ s{/+\z}{}; $f } ($x, $p);
    return ($f[1] eq $f[0] || index($f[1], "$f[0]/") == 0) ? 1 : 0;
}

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

# A helper-pasted Evidence line (template §4.9): Evidence:, Disposable:, Ref-only: or Volatile:.
sub _pasted { return $_[0] =~ /\A\s*(?:[-*]\s+)?(?:Evidence|Disposable|Ref-only|Volatile):/ ? 1 : 0 }

# Only what the helper itself printed (evidence_cmd.pm): its Volatile: lines end in its own
# `— missing at <stamp>` or `— withheld…` reason; a Volatile: line with the model's own reason
# is model-written text and counts toward the Evidence cap (0.1.2 handoff-lint).
sub _helper_pasted {
    my ($l) = @_;
    return 0 unless _pasted($l);
    return 1 unless $l =~ /\A\s*(?:[-*]\s+)?Volatile:/;
    return skills::util::text($l) =~ / — (?:missing at |withheld\b)/ ? 1 : 0;
}

# Lines that count for the overlap advisory (RV-30): not blank, not a
# heading, not a ledger line, not a fixed none-form, not a pasted Evidence
# line, not a table separator.
my $NONE;
sub _counts {
    my ($l) = @_;
    return 0 unless $l =~ /\S/;
    return 0 if $l =~ /\A#/;
    return 0 if $l =~ /\A\s*(?:[-*]\s+)?(?:[UDXQ]-\d+|Superseded:)/;
    return 0 if _pasted($l);
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

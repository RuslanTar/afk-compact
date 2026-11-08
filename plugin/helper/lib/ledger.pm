package ledger;
# lib/ledger.pm: the stable ledger, helper side (0.1.5, E-1; usage review "the helper copies U/D/X
# lines from the previous copy and lints the difference; ids unique across a chain"). Owner: WP-core.
# Pure text functions, no I/O: publish (skills::core seam) and the summary copies (copies.pm) call
# them with the spec literals they read themselves; the watcher reads a copy's carried lines with
# line_ids (watch::shape::uncarried). Text is characters.
#
#   check(base, draft, %o) -> {carry => [[line, section literal, [the ids it carries]]…], ids => [id…],
#                              changed => [[id, n]…], reused => [[id, n]…], renumbered => n}
#     base: the own chain's previous file (a handoff, or the session's newest earlier ok copy);
#     draft: the new body. n is the draft's 1-based line number.
#   carry(draft, check result, %o) -> the draft with the carried lines in their sections
#   o: sections (the spec's sections_main literals, in order), user (the User constraints
#      literal), decisions (the Decisions literal), approvals (the Approvals literal),
#      fold_re (the spec's fold_line_re), tag_re (carry.tag_re), none_res ([regex…]: the none-form
#      of User constraints), end_re (a line before which a missing section goes, e.g. the sentinel)
#   line_ids(line, \%o) -> {ids, kind, retired, to, first, defines} (below)
#
# A base line is carried when it is a ledger line of the base's User constraints or Decisions
# section (an entry `- U-3: …`, `- D-2: …`, `- X-1: …`, a `Superseded:` line, or a §7 fold or
# ledger.md pointer line) and the draft's User constraints, Approvals and Decisions have none of its
# ids: not as an entry, in the id list an entry or one of its merged clauses starts with, before
# `by` on a `Superseded:` line, nor on a fold or pointer line (the id after `by` names the item
# that took over, held only by its own entry; a line elsewhere that starts with the id only cites
# it; a carry tag's id is the other chain's and counts for nothing); an entry
# whose text the draft holds under another id (renumbered) is not carried either. Approval lines
# never are: an approval the draft drops stays dropped (the safe direction; the approval rules
# decide what carries). Lines are copied byte for byte, so the lint treats them as carried lines;
# an entry goes after the last entry of its kind in its kind's section (D- before X-), another line
# to the section it was in.
#
# The difference: a draft entry whose id a base entry has with other text is `changed` (an ask whose
# quoted request is the same, and an approval, only change state: not reported; check stamps are
# not text), or `reused` when the two name different items (_different_item: two whole entries,
# never a status line, whose identities share under half of their words, and of one form whose
# texts do too). Two draft entries with one id and different items are `reused` too, and so is a
# draft entry for an id the base folded, superseded or named after `by` without defining it: ids
# stay unique across the chain. Only the defining lines (led by one id: `- D-2: …`) of User
# constraints, Approvals and Decisions are compared: a line elsewhere, or one led by an id list,
# names the item.
use strict;
use warnings;
use utf8;

my $ID = qr/\b([UDX])-0*([0-9]+)\b/;
# between the ids of a list (as the watcher reads them): spaces, `,` `/` `&` `+`, and/or/to/through,
# an en dash
my $LIST_SEP = qr/(?:\s|,|\/|&|\+|\b(?:and|or|to|through)\b|\x{2013})/;
my $DASH = qr/\s(?:\x{2014}|\x{2013}|-{1,2})\s/;
my %STOP = map { $_ => 1 } qw(the and for with not but are was were this that from into onto its has have had
                               because user agent external rejected refuted failed ask approval scope status
                               open partly done superseded left ends start unknown none per via all any);

sub _id { return "$_[0]-" . ($_[1] + 0) }

# The ids a line defines or names: {ids => [...], kind, retired => [...], to => [...]}; also the
# watcher's reader of a copy's carried lines (watch::shape::uncarried), so the two never differ.
# kind: entry (an id leads the line), fold (§7 fold or ledger.md pointer line), superseded, or undef.
# retired: the ids that left the chain on the line (a fold line's, the ids before `by` on a
# Superseded line or mark); to: the ids after `by`, which ids leave out. A carry tag is read first
# and removed: the id it names is the other chain's.
# A tagged fold or pointer line keeps the other chain's ids, so they are named `<sid8>:<id>`.
# An id range is left out as the watcher leaves it out (`..` or `…`; a dash after an id is a
# separator), except before `by` on a Superseded line, where it names each id (at most 64).
my $RANGE = qr/\b[UDX]-[0-9]+\s*(?:\.\.|\x{2026})\s*(?:[UDX]-)?[0-9]+\b/;
sub _range_list {
    my ($k, $lo, $k2, $hi) = $_[0] =~ /\A([UDX])-0*([0-9]+)\s*(?:\.\.|\x{2026})\s*(?:([UDX])-)?0*([0-9]+)\z/ or return ();
    return () if (defined $k2 && $k2 ne $k) || $hi < $lo || $hi - $lo >= 64;
    return map { _id($k, $_) } $lo .. $hi;
}
sub line_ids { return _line_ids(@_) }
sub _line_ids {
    my ($l, $o) = @_;
    my $sid;
    if ($o->{tag_re} && $l =~ $o->{tag_re}) {
        ($sid) = substr($l, $-[0], $+[0] - $-[0]) =~ /\A\[from ([0-9a-f]{8})\b/;
        $l =~ s/$o->{tag_re}//g;
        $l =~ s/\s+\z//;
    }
    my $t = $l;
    $t =~ s/\A\s*(?:[-*]\s+)?//;
    my $entry = $t =~ /\A[UDX]-[0-9]+\b/;
    # A Superseded mark is `Superseded: <id>` outside quoted words. A line naming ledger.md is a
    # pointer line only when it says no item: not `- D-7: …`, and after its leading ids no ask,
    # quoted constraint, rejected option or because-clause (`- D-7 (45 s) — because …; see ledger.md`
    # is D-7's entry).
    (my $uq = $l) =~ s/"[^"]*"|\x{201c}[^\x{201d}]*\x{201d}//g;
    (my $rest = $t) =~ s/\A(?:$LIST_SEP*[UDX]-[0-9]+\b(?:\s*(?:\.\.|\x{2026})\s*(?:[UDX]-)?[0-9]+\b)?)+\s*(?:[:.)]|\x{2014}|\x{2013}|-)?\s*//;
    # An entry (`- D-4: …`) that ends in the tag form of the mark stays the entry and retires the ids
    # before its `by`.
    my $keyed = $t =~ /\A[UDX]-[0-9]+\s*:/;
    my $marked = $uq =~ /\bSuperseded:\s*[UDX]-[0-9]+\b/;
    my $kind = $marked && !$keyed ? 'superseded'
             : (($o->{fold_re} && $l =~ $o->{fold_re}) || $l =~ /\bsettled;\s*full text in\s/
                || ($l =~ /\bledger\.md\b/ && !$keyed && _form($rest) eq 'status')) ? 'fold' : undef;
    my ($old, $after) = _superseded($marked && ($kind // 'superseded') eq 'superseded' ? $l : '');
    if ($kind) {
        # A Superseded line holds the ids it retires; the id after `by` is held only by its own entry
        # or a fold line, so a draft that keeps the line and drops that entry has it carried.
        return { ids => [ @$old, @{ $after->{pre} } ], kind => $kind, retired => $old, to => $after->{to} }
            if $kind eq 'superseded' && $after->{by};
        (my $s = $l) =~ s/$RANGE//g;
        my @ids;
        push @ids, _id($1, $2) while $s =~ /$ID/g;
        my @retired = $kind eq 'fold' ? @ids : ();
        if ($kind eq 'fold' && defined $sid) { @ids = map { "$sid:$_" } @ids; @retired = () }
        return { ids => \@ids, kind => $kind, retired => \@retired };
    }
    return { ids => [], kind => undef } unless $entry;
    (my $s = $t) =~ s/$RANGE//g;
    my (@ids, %seen, $lead);
    for my $clause (split /;|\x{b7}|\|/, $s) {
        while ($clause =~ /\G$LIST_SEP*([UDX])-0*([0-9]+)\b/gc) { my $i = _id($1, $2); push @ids, $i unless $seen{$i}++ }
    }
    # the ids leading the line as written (a range there counts as more than one)
    $lead = 0;
    $lead++ while $t =~ /\G$LIST_SEP*[UDX]-[0-9]+\b(?:\s*(?:\.\.|\x{2026})\s*(?:[UDX]-)?[0-9]+\b)?/gc && $lead < 2;
    $lead = 2 if $lead == 1 && $t =~ /\A[UDX]-[0-9]+\s*(?:\.\.|\x{2026})/;
    return { ids => [], kind => undef } unless @ids;
    # Only a line led by one id (`- D-2: …`, `U-1 "…" — …`) defines an item; a line led by an id
    # list (`- D-7, D-8 kept …`) names them.
    return { ids => \@ids, kind => 'entry', first => $ids[0], defines => (($lead // 0) == 1 ? 1 : 0),
             retired => $old, to => $after->{to} };
}

# The ids a Superseded mark retires (before its `by`; a range names each id) and the rest:
# {by => 1 when it has a `by`, pre => the ids before the mark, to => the ids after `by`}.
sub _superseded {
    my ($l) = @_;
    my (@old, @pre, @to);
    return ([], { pre => [], to => [] }) unless $l =~ /\bSuperseded:\s*(.*?)\s+by\s/;
    my ($mark, $from, $end) = ($-[0], $-[1], $+[0]);
    my $head = $1;
    for my $r ($head =~ /($RANGE)/g) { push @old, _range_list($r) }
    (my $h = $head) =~ s/$RANGE//g;
    push @old, _id($1, $2) while $h =~ /$ID/g;
    (my $p = substr($l, 0, $mark)) =~ s/$RANGE//g;
    push @pre, _id($1, $2) while $p =~ /$ID/g;
    (my $t = substr($l, $end)) =~ s/$RANGE//g;
    push @to, _id($1, $2) while $t =~ /$ID/g;
    my %o = map { $_ => 1 } @old;
    return (\@old, { by => 1, pre => [ grep { !$o{$_} } @pre ], to => \@to });
}

# An entry's text without bullet, leading id and its separator, carry tags and check stamps
# (`[verified <stamp>: <cmd>]`, `(checked <stamp>)`, `checked <stamp>`: a refreshed check is the
# same line, as the watcher's norm_entry reads it); spaces folded.
my $STAMP = qr/[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T][0-9]{2}:[0-9]{2}(?::[0-9]{2})?)?(?:\s*(?:Z|[+-][0-9]{2}:?[0-9]{2}))?/;
sub _text {
    my ($l, $o) = @_;
    my $t = $l;
    $t =~ s/\A\s*(?:[-*]\s+)?[UDX]-[0-9]+\b\s*(?::|\.|\)|\x{2014}|-)?\s*//;
    $t =~ s/$o->{tag_re}//g if $o->{tag_re};
    $t =~ s/\s*\[verified\s+$STAMP[^\]\n]*\]//g;
    $t =~ s/\s*\(\s*(?:checked|verified)\s+$STAMP\s*\)//g;
    $t =~ s/\s*\b(?:checked|verified)\s+$STAMP//g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    return $t;
}

sub _norm { return lc _text(@_) }

sub _words {
    my ($s) = @_;
    my %w;
    for my $x (split /[^\w.\/-]+/, lc($s // '')) {
        $x =~ s/\A[.\/-]+|[.\/-]+\z//g;
        # a path or a dotted name counts as its parts too (`lib/ledger.pm`: lib, ledger)
        for my $y ($x, ($x =~ m{[./]} ? split(m{[./]+}, $x) : ())) {
            next unless length $y;
            next unless length($y) >= 3 || $y =~ /[0-9]/;
            next if $STOP{$y};
            $w{$y} = 1;
        }
    }
    return \%w;
}

# The words that name the item: the first quoted text, else the text before the first dash.
sub _identity {
    my ($text) = @_;
    return _words($1) if $text =~ /"([^"]+)"/ || $text =~ /\x{201c}([^\x{201d}]+)\x{201d}/;
    my ($head) = split $DASH, $text, 2;
    return _words($head);
}

sub _quote { my ($t) = @_; return ($t =~ /"([^"]+)"/ || $t =~ /\x{201c}([^\x{201d}]+)\x{201d}/) ? lc($1) =~ s/\s+/ /gr : undef }

# The share of the smaller word set that the other one holds, or undef when one is empty.
sub _share {
    my ($x, $y) = @_;
    my ($nx, $ny) = (scalar(keys %$x), scalar(keys %$y));
    return undef unless $nx && $ny;
    my $shared = grep { $y->{$_} } keys %$x;
    return $shared / ($nx < $ny ? $nx : $ny);
}

# The template form of an entry's text: approval, ask, constraint (`"<words>" — scope …`), option
# (`rejected …`, `refuted …`), decision (a because-clause), else status (`done (commit …)`,
# `done · U-3: done`: a state, not an item).
sub _form {
    my ($t) = @_;
    return $t =~ /\Aapproval\b/i ? 'approval' : $t =~ /\Aask\b/i ? 'ask' : $t =~ /\A["\x{201c}]/ ? 'constraint'
         : $t =~ /\A(?:rejected|refuted)\b/i ? 'option' : $t =~ /\bbecause\b/i ? 'decision' : 'status';
}

# Two texts of one id name different items (the id was reused) only when both are whole entries
# (never a status line) and their identities (the first quoted text, else the text before the
# first dash) share under half of their words; of one form, the whole texts must share under half
# too, so a reworded line or a changed choice with its reason kept stays one item (ledger-changed).
sub _different_item {
    my ($p, $q) = @_;
    my ($fa, $fb) = (_form($p), _form($q));
    return 0 if $fa eq 'status' || $fb eq 'status';
    my $id = _share(_identity($p), _identity($q));
    return 0 unless defined $id && $id < 0.5;
    return 1 if $fa ne $fb;
    my $all = _share(_words($p), _words($q));
    return defined $all && $all < 0.5 ? 1 : 0;
}

sub _approval { return $_[0] =~ /\A\s*(?:[-*]\s+)?U-[0-9]+:\s*approval\b/ ? 1 : 0 }
sub _ask { return _text($_[0], {}) =~ /\Aask\b/ ? 1 : 0 }

# [{n, text, sec, li}] with sec the literal of the `## ` section the line is in.
sub _scan {
    my ($text, $o) = @_;
    my (@out, $sec);
    my $n = 0;
    for my $l (split /\n/, $text // '', -1) {
        $n++;
        if ($l =~ /\A##\s/ && $l !~ /\A###/) {
            ($sec) = grep { index($l, $_) == 0 } @{ $o->{sections} || [] };
            $sec //= '';
            next;
        }
        push @out, { n => $n, text => $l, sec => $sec // '', li => _line_ids($l, $o) };
    }
    return \@out;
}

sub check {
    my ($base, $draft, %o) = @_;
    my $res = { carry => [], ids => [], changed => [], reused => [], renumbered => 0 };
    my $d = _scan($draft, \%o);
    my %ledger_sec = map { $_ => 1 } grep { defined && length } @o{qw(user decisions)};
    my %cmp_sec = (%ledger_sec, map { $_ => 1 } grep { defined && length } $o{approvals});
    my (%present, %dnorm, %dfirst);
    for my $r (@$d) {
        # Only the ledger sections hold or define items; a line elsewhere that starts with an id
        # (`- D-3 implemented — commit abc1234` in Work done) cites it.
        next unless $cmp_sec{ $r->{sec} };
        $present{$_} = 1 for @{ $r->{li}{ids} }, @{ $r->{li}{retired} || [] };
        next unless ($r->{li}{kind} // '') eq 'entry';
        $dnorm{ _norm($r->{text}, \%o) } = 1;
        next unless $r->{li}{defines};
        my $id = $r->{li}{first};
        if (my $f = $dfirst{$id}) {
            push @{ $res->{reused} }, [ $id, $r->{n} ]
                if !_approval($f->{text}) && !_approval($r->{text}) && _different_item(_text($f->{text}, \%o), _text($r->{text}, \%o));
        } else {
            $dfirst{$id} = $r;
        }
    }
    return $res unless defined $base && $base =~ /\S/;
    my $bs = _scan($base, \%o);
    my (%bfirst, %btaken, %carried);
    for my $r (@$bs) {
        my $k = $r->{li}{kind} // next;
        if ($k eq 'entry' && $r->{li}{defines} && $cmp_sec{ $r->{sec} } && !$bfirst{ $r->{li}{first} }) {
            $bfirst{ $r->{li}{first} } = $r;
        }
        # an id the base folds or supersedes has left the chain, and one a Superseded mark names after
        # `by` was given to an item: each is taken for good
        if ($cmp_sec{ $r->{sec} }) { $btaken{$_} //= $r for @{ $r->{li}{retired} || [] }, @{ $r->{li}{to} || [] } }
        # A Superseded line carries as a fold line does (template rule 8): the ids it retires stay
        # taken over the whole chain, not for one hop.
        next unless $ledger_sec{ $r->{sec} };
        next if $k eq 'entry' && _approval($r->{text});
        my @miss = grep { !$present{$_} } @{ $r->{li}{ids} };
        next unless @miss;
        if ($k eq 'entry' && $dnorm{ _norm($r->{text}, \%o) }) { $res->{renumbered}++; next }
        # an entry goes to the section of its kind, a Superseded, fold or pointer line to the one it was in
        my $to = $k ne 'entry' ? $r->{sec} : $r->{li}{first} =~ /\AU-/ ? $o{user} : $o{decisions};
        push @{ $res->{carry} }, [ $r->{text}, $to, [@miss] ];
        $carried{$_} = 1 for @miss;
    }
    $res->{ids} = [ sort { _ord($a) <=> _ord($b) || $a cmp $b } keys %carried ];
    for my $id (sort { _ord($a) <=> _ord($b) || $a cmp $b } keys %dfirst) {
        my $dr = $dfirst{$id};
        # a new entry for an id the base folded, superseded or named after `by` (and does not define)
        if (!$bfirst{$id} && $btaken{$id}) { push @{ $res->{reused} }, [ $id, $dr->{n} ]; next }
        my $br = $bfirst{$id} or next;
        my ($bt, $dt) = (_text($br->{text}, \%o), _text($dr->{text}, \%o));
        next if lc $bt eq lc $dt;
        if (_different_item($bt, $dt)) { push @{ $res->{reused} }, [ $id, $dr->{n} ]; next }
        next if _approval($br->{text}) || _approval($dr->{text});
        my ($qb, $qd) = (_quote($bt), _quote($dt));
        next if _ask($br->{text}) && _ask($dr->{text}) && defined $qb && defined $qd && $qb eq $qd;
        push @{ $res->{changed} }, [ $id, $dr->{n} ];
    }
    @{ $res->{reused} } = sort { $a->[1] <=> $b->[1] } @{ $res->{reused} };
    return $res;
}

# U before D before X, then by number; the ids of another chain's pointer line (`<sid8>:D-1`) last.
my %KIND_ORD = (U => 1, D => 2, X => 3);
sub _ord {
    my ($p, $k, $n) = $_[0] =~ /\A((?:[0-9a-f]{8}:)?)([UDX])-([0-9]+)\z/ or return 0;
    return (length $p ? 1e7 : 0) + $KIND_ORD{$k} * 1e6 + $n;
}

sub carry {
    my ($draft, $res, %o) = @_;
    return $draft unless $res && @{ $res->{carry} || [] };
    my @lines = split /\n/, $draft, -1;
    my $final_nl = @lines && $lines[-1] eq '' ? 1 : 0;
    pop @lines if $final_nl;
    for my $sec (grep { defined && length } $o{user}, $o{decisions}) {
        my @add = map { $_->[0] } grep { ($_->[1] // '') eq $sec } @{ $res->{carry} };
        next unless @add;
        _insert(\@lines, $sec, \@add, \%o);
    }
    return join("\n", @lines) . ($final_nl ? "\n" : '');
}

sub _heading_at {
    my ($l, $o) = @_;
    return undef unless $l =~ /\A##\s/ && $l !~ /\A###/;
    my $secs = $o->{sections} || [];
    for my $i (0 .. $#$secs) { return $i if index($l, $secs->[$i]) == 0 }
    return -1;
}

sub _insert {
    my ($lines, $sec, $add, $o) = @_;
    my $secs = $o->{sections} || [];
    my ($want) = grep { $secs->[$_] eq $sec } 0 .. $#$secs;
    my ($start, $end);
    for my $i (0 .. $#$lines) {
        my $h = _heading_at($lines->[$i], $o);
        next unless defined $h;
        if (defined $start) { $end = $i; last }
        $start = $i if $h == ($want // -2);
    }
    if (!defined $start) {
        # The section is missing: it goes before the first later section, else before end_re's line,
        # else at the end.
        my $at;
        for my $i (0 .. $#$lines) {
            my $h = _heading_at($lines->[$i], $o);
            if (defined $h && defined $want && $h > $want) { $at = $i; last }
        }
        if (!defined $at && $o->{end_re}) { for my $i (0 .. $#$lines) { if ($lines->[$i] =~ $o->{end_re}) { $at = $i; last } } }
        $at //= scalar @$lines;
        splice @$lines, $at, 0, $sec, @$add;
        return;
    }
    $end //= do {
        my $e = scalar @$lines;
        if ($o->{end_re}) { for my $i ($start + 1 .. $#$lines) { if ($lines->[$i] =~ $o->{end_re}) { $e = $i; last } } }
        $e;
    };
    my @body = grep { $lines->[$_] =~ /\S/ } $start + 1 .. $end - 1;
    # A lone none-form (`none stated`) gives way to the carried lines.
    if (@body == 1) {
        (my $v = $lines->[ $body[0] ]) =~ s/\A\s*(?:[-*]\s+)?|\s+\z//g;
        if (grep { $v =~ $_ } @{ $o->{none_res} || [] }) {
            splice @$lines, $body[0], 1, @$add;
            return;
        }
    }
    # Each entry goes after the section's last entry of its kind, else before the first entry of a
    # later kind (U, D, X) or a Superseded line, else after the section's last line, so D- lines stay
    # before X- lines as the template orders them; a fold or pointer line goes last.
    my %rank = (U => 1, D => 2, X => 3);
    for my $l (@$add) {
        my @b = grep { $lines->[$_] =~ /\S/ } $start + 1 .. $end - 1;
        my $k = _entry_kind($l, $o);
        my $at;
        if (defined $k) {
            my ($last) = reverse grep { (_entry_kind($lines->[$_], $o) // '') eq $k } @b;
            if (defined $last) { $at = $last + 1 }
            else {
                ($at) = grep { my $x = _entry_kind($lines->[$_], $o);
                               (defined $x && $rank{$x} > $rank{$k}) || (_line_ids($lines->[$_], $o)->{kind} // '') eq 'superseded' } @b;
            }
        }
        $at //= @b ? $b[-1] + 1 : $start + 1;
        splice @$lines, $at, 0, $l;
        $end++;
    }
}

# The kind letter of an entry line (`- D-2: …` -> D), else undef (a fold, Superseded or other line).
sub _entry_kind {
    my ($l, $o) = @_;
    my $li = _line_ids($l, $o);
    return undef unless ($li->{kind} // '') eq 'entry' && defined $li->{first};
    return substr($li->{first}, 0, 1);
}

# The frontmatter value a summary copy records: `<n> lines (U-3, D-2); sha256 <summary sha>`.
sub copy_note {
    my ($res, $sha) = @_;
    my $n = scalar @{ $res->{carry} || [] };
    return sprintf('%d line%s (%s); sha256 %s', $n, ($n == 1 ? '' : 's'), join(', ', @{ $res->{ids} }), $sha);
}

1;

package skills::approvals;
# lib/skills/approvals.pm: scoped approvals (spec §4 Approval (scoped), §8 approvals_checked,
# §15 approval-shape / approval-quote / approval-unchecked; SPEC-DELTAS AP-4, AP-5). Owner:
# WP-skills.
#
#   lint(\@lines, %a)          the three publish checks; returns the ids whose quote passed
#   handoff_lines(doc, ctx, sid) the `Approvals (checked)` lines of `measure <handoff>`
#   summary_lines(text, path)  the same for a compaction summary's copy (`measure --compact --copy`)
#   classes(entry)             the outward class ids an approval's action names, and its gate
#
# Quotes are checked in memory against the writing session's human-typed user rows
# (transcript::quotes_found); no quote, action or target text is logged: rows carry counts and
# class ids only.
#
# PROVISIONAL (owner decisions open, recommended reading built; REVIEW-NIGHT-2 §3):
#   O-3   code checks the quote (this module at all);
#   O-1   only the own chain carries: a foreign handoff's approvals are never listed as checked;
#   O-12  $NO_CARRY_REASON: a predecessor reached by `fork` or `bg-copy` carries no approvals;
#   O-2   strict half only: an approval that names production is a gate (re-ask), read or write
#         ($PROD_IS_GATE); the looser half (a production read under forbid) is not built;
#   gates from text: $ACTION_WORDS reads a plain-words action ("push feat/x") into outward
#         class ids, and a push that names no branch, or a protected one, is protected-push
#         ($PUSH_UNNAMED_IS_GATE), as `risk` counts an unknown push destination.
use strict;
use warnings;
use utf8;
use skills::util;
use skills::spec;
use skills::core;
use skills::ctx;
use skills::store;

our $HEADING = '## Approvals';
our %NO_CARRY_REASON = map { $_ => 1 } qw(fork bg-copy);
our $PROD_IS_GATE = 1;
our $PUSH_UNNAMED_IS_GATE = 1;
our $ENTRY_MAX = 160;
# Plain words of an action, read as outward class ids when no class pattern matched the text.
our @ACTION_WORDS = (
    [ 'force-push', qr/\bforce[- ]?push|--force\b/i ],
    [ 'push', qr/\bpush/i ],
    [ 'mr-write', qr/\b(?:merge|pull)[- ]request|\b(?:MR|PR)s?\b|![0-9]+/ ],
    [ 'publish', qr/\bpublish|\brelease\b/i ],
    [ 'deploy', qr/\bdeploy|\broll[- ]?out\b/i ],
    [ 'env-write', qr/\bsecrets?\b|\benv(?:ironment)?[- ]var|\bconfig[- ]var/i ],
    [ 'infra-write', qr/\bterraform|\btofu\b|\bpulumi|\bkubectl|\bhelm\b|\binfra(?:structure)?\b/i ],
    [ 'history-rewrite', qr/\brebase|\bamend|\bsquash|reset --hard/i ],
    [ 'recursive-delete', qr/\bdelete|\bwipe|\bdrop\b|\brm -r/i ],
    [ 'http-write', qr/\b(?:POST|PUT|PATCH|DELETE)\b|\bwebhook/ ],
);
my $LINE_RE = qr/\bU-[0-9]+:\s*approval\b/;
# Loose form for compaction summaries (the summary writes several on one line or a list).
my $LOOSE_RE = qr/U-([0-9]+):?[ \t]+approval[ \t]+"([^"]+)"[ \t]+—[ \t]+action[ \t]+(.+?)[ \t]+·[ \t]+targets[ \t]+(.+?)[ \t]+·[ \t]+(once|standing(?:[ \t]*\([^)]*\))?)[ \t]+·[ \t]+(not yet used|used[ \t]+[0-9]{4}-[0-9]{2}-[0-9]{2}[ \t]+[0-9]{2}:[0-9]{2}(?:[ \t]+[+-][0-9]{4})?)/;

# The spec knows the section (a spec older than AP-3 has no approvals: nothing is checked).
sub enabled {
    return 0 unless eval { skills::spec::need('approval_re'); 1 };
    my $ids = skills::spec::lint_ids();
    return 0 unless $ids->{blocking}{'approval-shape'} && $ids->{blocking}{'approval-quote'} && $ids->{advisory}{'approval-unchecked'};
    return (grep { $_->{literal} eq $HEADING } @{ skills::spec::sections_main() }) ? 1 : 0;
}

sub is_approval_line { my ($l) = @_; return defined $l && $l =~ $LINE_RE ? 1 : 0 }

# parse_line(line) -> {n, id, quote, action, targets => [..], targets_text, scope, state, used}
# for a line in the spec's approval_re form, else undef.
sub parse_line {
    my ($l) = @_;
    my $re = skills::spec::regex_at('approval_re') or return undef;
    return undef unless defined $l && $l =~ $re;
    my %e = (n => $1, quote => $2, action => $3, targets_text => $4, scope => $5, state => $7);
    $e{id} = "U-$e{n}";
    return _finish(\%e);
}

sub _finish {
    my ($e) = @_;
    $e->{targets} = [ grep { /\S/ } map { s/\A\s+|\s+\z//gr } split /,\s+/, $e->{targets_text} ];
    $e->{used} = $e->{state} =~ /\Aused\b/ ? 1 : 0;
    $e->{standing} = $e->{scope} =~ /\Astanding\b/ ? 1 : 0;
    return $e;
}

# section_lines(\@lines) -> {index => 1} for the body lines of `## Approvals`.
sub section_lines {
    my ($lines) = @_;
    my (%in, $on);
    for my $i (0 .. $#$lines) {
        my $l = $lines->[$i];
        if ($l =~ /\A##\s/ && $l !~ /\A###/) { $on = ($l =~ /\A\Q$HEADING\E\s*\z/) ? 1 : 0; next }
        $in{$i} = 1 if $on;
    }
    return \%in;
}

# classes(entry) -> {outward => [class ids], gate => gate id | undef}
sub classes {
    my ($e) = @_;
    my $text = "$e->{action} · $e->{targets_text}";
    my (@ids, %seen);
    for my $c (@{ (eval { skills::spec::outward_classes() }) || [] }) {
        push @ids, $c->{class} if $text =~ $c->{re} && !$seen{ $c->{class} }++;
    }
    if (!@ids) {
        for my $w (@ACTION_WORDS) { push @ids, $w->[0] if $e->{action} =~ $w->[1] && !$seen{ $w->[0] }++ }
    }
    push @ids, 'push' if $seen{'force-push'} && !$seen{push}++;
    my %gates = map { $_ => 1 } @{ (eval { skills::spec::get(q(explicit_gate_classes)) }) || [] };
    my ($gate) = grep { $gates{$_} } @ids;
    if (!defined $gate && $PROD_IS_GATE) {
        my $prod = skills::core::prod();
        for my $c (@{ ref $prod->{classes} eq 'ARRAY' ? $prod->{classes} : [] }) {
            next unless ref $c eq 'HASH' && defined $c->{re};
            if ($text =~ $c->{re}) { $gate = 'prod-write'; last }
        }
    }
    if (!defined $gate && $seen{push}) {
        my $pre = skills::spec::regex_at('protected_branch_re');
        my ($named, $protected) = (0, 0);
        for my $t (@{ $e->{targets} }, $e->{action}) {
            my $id = $t =~ s/\s+@\s.*\z//sr;
            for my $w (split /[\s`'"]+/, $id) {
                $w =~ s/[.,;:)]+\z//;
                next if $w eq '';
                my $b = $w =~ s{\A(?:refs/heads/|[A-Za-z0-9._-]+:)}{}r;
                $b =~ s{\A(?:origin|upstream)/}{};
                $protected = 1 if $pre && $b =~ $pre;
            }
            $named = 1 if $id =~ /\bbranch[ \t]+\S/i || $id =~ m{[A-Za-z0-9._-]/[A-Za-z0-9._/-]};
        }
        $gate = 'protected-push' if $protected || (!$named && $PUSH_UNNAMED_IS_GATE);
    }
    return { outward => \@ids, gate => $gate };
}

# lint(\@lines, prev_lines => {line => 1}, tag_re => qr, note => text,
#      chain => [{text, checked => {U-n => 1}}], transcript => path | undef)
#   -> {blocking => [[rule, where]…], advisory => [...], checked => [U-n…], lines => n,
#       unchecked => n, classes => [outward ids of checked approvals]}
sub lint {
    my ($lines, %a) = @_;
    my %r = (blocking => [], advisory => [], checked => [], lines => 0, unchecked => 0, classes => []);
    return \%r unless enabled();
    my $in = section_lines($lines);
    my ($tag_re, $note) = ($a{tag_re}, $a{note} // '');
    my @own;
    for my $i (0 .. $#$lines) {
        my $l = $lines->[$i];
        my $tagged = $tag_re && $l =~ $tag_re ? 1 : 0;
        my $where = 'line ' . ($i + 1);
        if (!$in->{$i}) {
            # An approval line outside the section: new ones are flagged; a line carried
            # byte-identical from the base or own file, or a tagged carried line, is context.
            push @{ $r{blocking} }, [ 'approval-shape', $where ] if is_approval_line($l) && !$tagged && !$a{prev_lines}{$l};
            next;
        }
        next unless $l =~ /\S/;
        $r{lines}++;
        if ($tagged) {
            push @{ $r{blocking} }, [ 'approval-shape', $where ] unless $l =~ $LINE_RE && $l =~ /"[^"]+"/ && index($l, $note) >= 0;
            next;
        }
        my $e = parse_line($l);
        if (!$e) { push @{ $r{blocking} }, [ 'approval-shape', $where ]; next }
        $e->{where} = $where;
        push @own, $e;
    }
    my @ask;
    for my $e (@own) {
        if (_carried($e, $a{chain})) { $e->{ok} = 1; next }
        push @ask, $e;
    }
    if (@ask) {
        my $res = defined $a{transcript}
            ? skills::core::quotes_found($a{transcript}, [ map { { quote => $_->{quote}, targets => $_->{targets} } } @ask ])
            : undef;
        for my $k (0 .. $#ask) {
            my $v = $res ? $res->[$k] : undef;
            if (!defined $v) { push @{ $r{advisory} }, [ 'approval-unchecked', $ask[$k]{where} ]; $r{unchecked}++ }
            elsif ($v) { $ask[$k]{ok} = 1 }
            else { push @{ $r{blocking} }, [ 'approval-quote', $ask[$k]{where} ] }
        }
    }
    my %cls;
    for my $e (grep { $_->{ok} } @own) {
        push @{ $r{checked} }, $e->{id};
        $cls{$_} = 1 for @{ classes($e)->{outward} };
    }
    $r{classes} = [ sort keys %cls ];
    return \%r;
}

# A line carried from an own-chain file that listed its id in approvals_checked: the same id,
# words, action, targets and once/standing; its state may go from `not yet used` to `used`.
sub _carried {
    my ($e, $chain) = @_;
    for my $d (@{ $chain || [] }) {
        next unless $d->{checked}{ $e->{id} };
        for my $l (split /\n/, $d->{text} // '') {
            my $p = parse_line($l) or next;
            next unless $p->{id} eq $e->{id} && $p->{quote} eq $e->{quote} && $p->{action} eq $e->{action}
                && $p->{targets_text} eq $e->{targets_text} && $p->{scope} eq $e->{scope};
            return 1 if $p->{state} eq 'not yet used' || $p->{state} eq $e->{state};
        }
    }
    return 0;
}

# The ids of a frontmatter approvals_checked value.
sub checked_ids {
    my ($v) = @_;
    return {} unless defined $v && !ref $v;
    return { map { $_ => 1 } grep { /\AU-[0-9]+\z/ } split /\s*,\s*/, $v };
}

# An own-chain document for the carry check: {text, checked}.
sub chain_doc {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $d = skills::store::read_doc($path) or return undef;
    return { text => $d->{body} // '', checked => checked_ids($d->{fm}{approvals_checked}) };
}

# transcript_path(ctx, sid, cwd…) -> this session's transcript, or undef: <config dir>/projects/
# <slug of a cwd>/<sid>.jsonl for the given folders, then the session's process records.
sub transcript_path {
    my ($ctx, $sid, @cwds) = @_;
    return undef unless skills::ctx::valid_sid($sid);
    my $cfg = skills::util::env('CLAUDE_CONFIG_DIR') // ((skills::util::env('HOME') // '') . '/.claude');
    my %seen;
    for my $c (grep { defined && $_ ne '' } map { ($_, skills::util::abs_path($_)) } grep { defined } @cwds) {
        next if $seen{$c}++;
        (my $slug = $c) =~ s/[^A-Za-z0-9]/-/g;
        my $p = "$cfg/projects/$slug/$sid.jsonl";
        return $p if -f $p;
    }
    if ($ctx) {
        require skills::jobs;
        return skills::jobs::transcript_of($ctx, $sid, undef);
    }
    return undef;
}

sub _entry {
    my ($e) = @_;
    my $t = "$e->{id} $e->{action} → " . join(', ', @{ $e->{targets} });
    $t = substr($t, 0, $ENTRY_MAX - 1) . '…' if length($t) > $ENTRY_MAX;
    return $t;
}

# The own relation of a handoff to this session (O-1, O-12): (1, '') when it is own, else
# (0, why).
sub own_relation {
    my ($d, $ctx, $sid) = @_;
    my $fm = $d->{fm} || {};
    return (0, 'export') if defined $fm->{export};
    return (0, 'imported') if defined $fm->{imported_from};
    return (0, 'not a handoff') unless ($fm->{kind} // '') eq 'handoff';
    my $int = skills::store::integrity($d)->{integrity} // '';
    return (0, $int eq '' ? 'integrity unknown' : $int) unless $int eq 'ok';
    my $hs = $fm->{session_id} // '';
    return (1, '') if $hs ne '' && defined $sid && $hs eq $sid;
    for my $c (@{ skills::ctx::chain($ctx, $sid) }) {
        next unless $c->{sid} eq $hs;
        return $NO_CARRY_REASON{ $c->{reason} } ? (0, $c->{reason}) : (1, '');
    }
    return (0, 'foreign');
}

# handoff_lines(doc, ctx, sid) -> (lines, row): `measure <handoff>` (AP-5).
sub handoff_lines {
    my ($d, $ctx, $sid) = @_;
    return ([], undef) unless enabled();
    my @lines = split /\n/, $d->{body} // '';
    my $in = section_lines(\@lines);
    my @e = grep { defined } map { parse_line($lines[$_]) } sort { $a <=> $b } keys %$in;
    my ($own, $why) = own_relation($d, $ctx, $sid);
    if (!$own) {
        return ([ 'Approvals (checked): none (' . $why . ': context only)' ], { source => 'handoff', checked => 0, gate => 0, classes => [] }) if @e;
        return ([ 'Approvals (checked): none' ], { source => 'handoff', checked => 0, gate => 0, classes => [] });
    }
    my $ok = checked_ids($d->{fm}{approvals_checked});
    return _report([ grep { $ok->{ $_->{id} } } @e ], [], 'handoff');
}

# summary_lines(copy text, transcript path) -> (lines, row): `measure --compact --copy` (AP-5).
sub summary_lines {
    my ($text, $transcript) = @_;
    return ([], undef) unless enabled();
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my (@e, %seen);
    for my $l (split /\n/, $text // '') {
        next if $tag_re && $l =~ $tag_re;
        while ($l =~ /$LOOSE_RE/g) {
            my %x = (n => $1, quote => $2, action => $3, targets_text => $4, scope => $5, state => $6);
            $x{id} = "U-$x{n}";
            next if $seen{ $x{id} }++;
            push @e, _finish(\%x);
        }
    }
    return ([ 'Approvals (checked): none' ], { source => 'summary', checked => 0, gate => 0, classes => [] }) unless @e;
    my $res = defined $transcript ? skills::core::quotes_found($transcript, [ map { { quote => $_->{quote}, targets => $_->{targets} } } @e ]) : undef;
    my (@ok, @no);
    for my $k (0 .. $#e) { if ($res && $res->[$k]) { push @ok, $e[$k] } else { push @no, $e[$k] } }
    return _report(\@ok, \@no, 'summary');
}

sub _report {
    my ($ok, $no, $source) = @_;
    my (@carry, @gate, %cls);
    for my $e (@$ok) {
        my $c = classes($e);
        if (defined $c->{gate}) { push @gate, $e; next }
        next if $e->{used} && !$e->{standing};
        push @carry, $e;
        $cls{$_} = 1 for @{ $c->{outward} };
    }
    my @out = ('Approvals (checked): ' . (@carry ? join('; ', map { _entry($_) } @carry) : 'none'));
    push @out, 'Approvals (gate, re-ask): ' . join('; ', map { _entry($_) } @gate) if @gate;
    push @out, 'Approvals (unchecked): ' . join(', ', map { $_->{id} } @$no) if @$no;
    return (\@out, { source => $source, checked => scalar(@carry), gate => scalar(@gate), unchecked => scalar(@$no),
                     classes => [ sort keys %cls ] });
}

1;

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
#         ($PUSH_UNNAMED_IS_GATE), as `risk` counts an unknown push destination;
#         REVIEW-NIGHT-3 R3-02: a gate named in plain words counts beside a class pattern's hit,
#         the remote default branch is protected as in `risk`, and a local merge (not a merge
#         request) whose words name a protected branch is protected-push;
#   quotes (transcript::quotes_found, R3-04): whole words; a quote under 4 words is the whole
#         message; a message holding an approval line was pasted and does not count.
#
# Line hashes (REVIEW-NIGHT-3 U3-01; root ruling 2026-10-23 11:56, a must-have before unattended
# use): publish records a SHA-256 of each checked `## Approvals` line, keyed by its id, in a
# plugin-owned record of the private store (`.sessions/approvals/<sid>.<nonce>.json`, never in
# the handoff file, never rewritten). Before any carry (`measure <handoff>`, which resume reads,
# and publish's own-chain carry) a checked id counts only when the file holds exactly one line
# with that id and the line's hash equals the record: an added line, an edited quote, action,
# target or id, a file with no record (published before the hashes) or a record without the id
# makes the line context only (re-ask).
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::spec;
use skills::core;
use skills::ctx;
use skills::store;
use skills::gitfacts;

our $HEADING = '## Approvals';
our %NO_CARRY_REASON = map { $_ => 1 } qw(fork bg-copy);
our $PROD_IS_GATE = 1;
our $PUSH_UNNAMED_IS_GATE = 1;
our $ENTRY_MAX = 160;
our $HASH_DIR = 'approvals';                 # under <handoff_root>/.sessions/
my $NONCE_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;
our %HASH_WHY = (unhashed => 'no hash recorded', missing => 'not in the publish record', changed => 'changed since publish');
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

# classes(entry [, cwd]) -> {outward => [class ids], gate => gate id | undef}
# The outward ids are the class patterns' hits on the action and targets, else the plain
# words' ($ACTION_WORDS). The gate is read from both (REVIEW-NIGHT-3 R3-02: "git push origin
# feat/x and deploy" names a deploy although a class pattern matched the push). A push, or a
# local merge (not a merge request), whose words name a protected branch is protected-push:
# protected_branch_re or the remote default branch of origin or upstream in cwd, each side of a
# `src:dst` refspec and a name after its remote prefix (`fork/main`) counted.
sub classes {
    my ($e, $cwd) = @_;
    my $text = "$e->{action} · $e->{targets_text}";
    my (@ids, %seen, %word);
    for my $c (@{ (eval { skills::spec::outward_classes() }) || [] }) {
        push @ids, $c->{class} if $text =~ $c->{re} && !$seen{ $c->{class} }++;
    }
    for my $w (@ACTION_WORDS) { $word{ $w->[0] } = 1 if $e->{action} =~ $w->[1] }
    if (!@ids) {
        for my $w (@ACTION_WORDS) { push @ids, $w->[0] if $word{ $w->[0] } && !$seen{ $w->[0] }++ }
    }
    push @ids, 'push' if $seen{'force-push'} && !$seen{push}++;
    my %any = (%seen, %word);
    $any{push} = 1 if $any{'force-push'};
    my %gates = map { $_ => 1 } @{ (eval { skills::spec::get(q(explicit_gate_classes)) }) || [] };
    my ($gate) = grep { $gates{$_} } @ids, (grep { $word{$_} } map { $_->[0] } @ACTION_WORDS);
    if (!defined $gate && $PROD_IS_GATE) {
        my $prod = skills::core::prod();
        for my $c (@{ ref $prod->{classes} eq 'ARRAY' ? $prod->{classes} : [] }) {
            next unless ref $c eq 'HASH' && defined $c->{re};
            if ($text =~ $c->{re}) { $gate = 'prod-write'; last }
        }
    }
    my $merge = $e->{action} =~ /\bmerge\b/i && !$any{'mr-write'};
    if (!defined $gate && ($any{push} || $merge)) {
        my $pre = skills::spec::regex_at('protected_branch_re');
        my %def = map { $_ => 1 } _default_branches($cwd);
        my ($named, $protected) = (0, 0);
        for my $t (@{ $e->{targets} }, $e->{action}) {
            my $id = $t =~ s/\s+@\s.*\z//sr;
            for my $w (split /[\s`'"]+/, $id) {
                $w =~ s/[.,;)]+\z//;
                next if $w eq '';
                for my $part (split /:/, $w) {
                    my $b = $part =~ s{\A\+}{}r;
                    $b =~ s{\Arefs/(?:heads|remotes)/}{};
                    for my $n ($b, ($b =~ m{\A[^/]+/(.+)\z} ? $1 : ())) {
                        $protected = 1 if ($pre && lc($n) =~ $pre) || $def{$n};
                    }
                }
            }
            $named = 1 if $id =~ /\bbranch[ \t]+\S/i || $id =~ m{[A-Za-z0-9._-]/[A-Za-z0-9._/-]};
        }
        $gate = 'protected-push' if $protected || ($any{push} && !$named && $PUSH_UNNAMED_IS_GATE);
    }
    return { outward => \@ids, gate => $gate };
}

# The default branches of the remotes origin and upstream in cwd (refs/remotes/<r>/HEAD), the
# spec's "the remote's default branch" of protected-push; () outside git.
my %DEFAULT_BRANCHES;
sub _default_branches {
    my ($cwd) = @_;
    $cwd //= skills::util::cwd();
    return () unless defined $cwd;
    $DEFAULT_BRANCHES{$cwd} //= do {
        my @b;
        for my $r (qw(origin upstream)) {
            my $x = eval { skills::gitfacts::line(skills::gitfacts::git($cwd, 'symbolic-ref', '--short', '-q', "refs/remotes/$r/HEAD")) };
            push @b, $1 if defined $x && $x =~ m{\A\Q$r\E/(.+)\z};
        }
        \@b;
    };
    return @{ $DEFAULT_BRANCHES{$cwd} };
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
        # One line per id (REVIEW-NIGHT-3 R3-05): approvals_checked lists ids, so a second line
        # with a checked line's id would ride on its check.
        if (grep { $_->{id} eq $e->{id} } @own) { push @{ $r{blocking} }, [ 'approval-shape', $where ]; next }
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
            ? skills::core::quotes_found($a{transcript}, [ map { { quote => $_->{quote}, targets => $_->{targets} } } @ask ], $a{sid})
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

# An own-chain document for the carry check: {text, checked}; undef unless the file is own for
# this session by own_relation (REVIEW-NIGHT-3 R3-03: a fork's or bg-copy's base, an export, an
# imported copy or a file outside the store lends no checked approvals to the new handoff).
# Only checked ids whose line matches the publish record carry (U3-01).
sub chain_doc {
    my ($path, $ctx, $sid) = @_;
    return undef unless defined $path && -f $path;
    my $d = skills::store::read_doc($path) or return undef;
    my ($own) = own_relation($d, $ctx, $sid);
    return undef unless $own;
    my ($good) = verify_checked($ctx, $d, checked_ids($d->{fm}{approvals_checked}));
    return { text => $d->{body} // '', checked => $good };
}

# ---- line hashes (U3-01)

sub line_hash { my ($l) = @_; return skills::util::sha256_hex($l // '') }

# The record's path for a handoff's session_id and nonce, or undef (no store, a bad key).
sub hash_path {
    my ($ctx, $fm) = @_;
    return undef unless $ctx && defined $ctx->{root} && ref $fm eq 'HASH';
    my ($sid, $n) = ($fm->{session_id} // '', $fm->{nonce} // '');
    return undef unless skills::ctx::valid_sid($sid) && $n =~ $NONCE_RE;
    return "$ctx->{root}/.sessions/$HASH_DIR/$sid.$n.json";
}

# The parsed, untagged lines of a body's `## Approvals`, each with its exact text.
sub _section_entries {
    my ($body) = @_;
    my @lines = split /\n/, $body // '';
    my $in = section_lines(\@lines);
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my @out;
    for my $i (sort { $a <=> $b } keys %$in) {
        next if $tag_re && $lines[$i] =~ $tag_re;
        my $e = parse_line($lines[$i]) or next;
        $e->{line} = $lines[$i];
        push @out, $e;
    }
    return \@out;
}

# record_hashes(ctx, doc, \@ids) -> (n hashed, undef) | (0, why): publish, after the handoff is
# placed and read back. Exclusive create: an existing record is never rewritten (the same
# record again, from a retry, is fine).
sub record_hashes {
    my ($ctx, $d, $ids) = @_;
    my %want = map { $_ => 1 } @{ $ids || [] };
    return (0, undef) unless %want;
    my $p = hash_path($ctx, $d->{fm}) or return (0, 'no-key');
    my %h;
    for my $e (@{ _section_entries($d->{body}) }) {
        next unless $want{ $e->{id} };
        return (0, 'duplicate') if exists $h{ $e->{id} };
        $h{ $e->{id} } = line_hash($e->{line});
    }
    return (0, 'no-line') unless %h;
    my $json = skills::util::json_encode({ v => 1, session_id => $d->{fm}{session_id}, nonce => $d->{fm}{nonce}, lines => \%h }) . "\n";
    my $ok = eval {
        skills::util::mkdir_p(File::Basename::dirname($p));
        skills::util::write_excl($p, $json, 0600);
    };
    return (0, 'write') unless defined $ok;
    return (scalar(keys %h), undef) if $ok;
    my $have = skills::util::read_file($p, 65536);
    return (defined $have && $have eq $json) ? (scalar(keys %h), undef) : (0, 'exists');
}

# The record of a handoff: {U-n => hex}, or undef when there is none or it does not fit the file.
sub hashes_of {
    my ($ctx, $d) = @_;
    my $p = hash_path($ctx, $d->{fm}) or return undef;
    return undef unless -f $p && !-l $p;
    my $r = eval { skills::util::json_decode(skills::util::read_file($p, 65536)) };
    return undef unless ref $r eq 'HASH' && ($r->{v} // 0) eq '1' && ref $r->{lines} eq 'HASH'
        && ($r->{session_id} // '') eq ($d->{fm}{session_id} // '') && ($r->{nonce} // '') eq ($d->{fm}{nonce} // '');
    my %h;
    for my $id (keys %{ $r->{lines} }) {
        my $x = $r->{lines}{$id};
        $h{$id} = $x if $id =~ /\AU-[0-9]+\z/ && defined $x && !ref $x && $x =~ /\A[0-9a-f]{64}\z/;
    }
    return \%h;
}

# verify_checked(ctx, doc, {U-n => 1}) -> ({U-n => 1} verified, {U-n => unhashed|missing|changed})
# for the checked ids that have a line in `## Approvals`; an id on two lines is changed.
sub verify_checked {
    my ($ctx, $d, $ok) = @_;
    my (%good, %why, %lines);
    push @{ $lines{ $_->{id} } }, $_->{line} for @{ _section_entries($d->{body}) };
    my $rec = hashes_of($ctx, $d);
    for my $id (sort keys %{ $ok || {} }) {
        my $l = $lines{$id} or next;
        if (!$rec) { $why{$id} = 'unhashed' }
        elsif (!defined $rec->{$id}) { $why{$id} = 'missing' }
        elsif (@$l == 1 && line_hash($l->[0]) eq $rec->{$id}) { $good{$id} = 1 }
        else { $why{$id} = 'changed' }
    }
    return (\%good, \%why);
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

# The own relation of a handoff to this session (spec §4 Own handoff; O-1, O-12): (1, '') when
# it is own, else (0, why). Own: a handoff in the private store (handoff_root; REVIEW-NIGHT-3
# R3-03), not an export or an imported copy, integrity ok, written by this session or by a
# lineage predecessor reached without a fork or bg-copy link anywhere on the way (a link of
# that kind cuts off every session before it too).
sub own_relation {
    my ($d, $ctx, $sid) = @_;
    my $fm = $d->{fm} || {};
    return (0, 'export') if defined $fm->{export};
    return (0, 'imported') if defined $fm->{imported_from};
    return (0, 'not a handoff') unless ($fm->{kind} // '') eq 'handoff';
    return (0, 'outside the store') unless _in_store($d->{path}, $ctx);
    my $int = skills::store::integrity($d)->{integrity} // '';
    return (0, $int eq '' ? 'integrity unknown' : $int) unless $int eq 'ok';
    my $hs = $fm->{session_id} // '';
    return (1, '') if $hs ne '' && defined $sid && $hs eq $sid;
    return (0, 'foreign') unless defined $sid;
    my $cut;
    for my $c (@{ skills::ctx::chain($ctx, $sid) }) {
        $cut //= $c->{reason} if $NO_CARRY_REASON{ $c->{reason} };
        next unless $c->{sid} eq $hs;
        return defined $cut ? (0, $cut) : (1, '');
    }
    return (0, 'foreign');
}

# 1 when the file's real path lies under the store root (handoff_root), component by component.
sub _in_store {
    my ($path, $ctx) = @_;
    return 0 unless defined $path && $ctx && defined $ctx->{root};
    my $p = skills::util::abs_path($path);
    my $r = skills::util::abs_path($ctx->{root});
    return 0 unless defined $p && defined $r;
    $r =~ s{/+\z}{};
    return index($p, "$r/") == 0 ? 1 : 0;
}

# handoff_lines(doc, ctx, sid) -> (lines, row): `measure <handoff>` (AP-5).
sub handoff_lines {
    my ($d, $ctx, $sid) = @_;
    return ([], undef) unless enabled();
    my @lines = split /\n/, $d->{body} // '';
    my $in = section_lines(\@lines);
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my @e = grep { defined } map { parse_line($lines[$_]) } grep { !($tag_re && $lines[$_] =~ $tag_re) } sort { $a <=> $b } keys %$in;
    my ($own, $why) = own_relation($d, $ctx, $sid);
    if (!$own) {
        return ([ 'Approvals (checked): none (' . $why . ': context only)' ], { source => 'handoff', checked => 0, gate => 0, classes => [] }) if @e;
        return ([ 'Approvals (checked): none' ], { source => 'handoff', checked => 0, gate => 0, classes => [] });
    }
    # U3-01: a checked id carries only when its line matches the hash publish recorded.
    my ($ok, $why) = verify_checked($ctx, $d, checked_ids($d->{fm}{approvals_checked}));
    # An id on two lines is no one's check (R3-05; publish refuses it, an edited file may not).
    my %n;
    $n{ $_->{id} }++ for @e;
    my ($out, $row) = _report([ grep { $ok->{ $_->{id} } && $n{ $_->{id} } == 1 } @e ], [], 'handoff');
    my @bad = sort { (substr($a, 2) <=> substr($b, 2)) } keys %$why;
    if (@bad) {
        push @$out, 'Approvals (context only, re-ask): ' . join(', ', map { "$_ ($HASH_WHY{ $why->{$_} })" } @bad);
        $row->{unverified} = scalar @bad;
    }
    return ($out, $row);
}

# summary_lines(copy text, transcript path [, cwd, sid]) -> (lines, row): `measure --compact --copy` (AP-5).
sub summary_lines {
    my ($text, $transcript, $cwd, $sid) = @_;
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
    my $res = defined $transcript ? skills::core::quotes_found($transcript, [ map { { quote => $_->{quote}, targets => $_->{targets} } } @e ], $sid) : undef;
    my (@ok, @no);
    for my $k (0 .. $#e) { if ($res && $res->[$k]) { push @ok, $e[$k] } else { push @no, $e[$k] } }
    return _report(\@ok, \@no, 'summary', $cwd);
}

sub _report {
    my ($ok, $no, $source, $cwd) = @_;
    my (@carry, @gate, %cls);
    for my $e (@$ok) {
        my $c = classes($e, $cwd);
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

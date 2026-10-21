package secrets;
# lib/secrets.pm: the shared secret rule set (MOD-SPEC §10, template §5), read from
# the spec literals (`secret_rules`: [{id, class HARD|WARN, re, min_entropy?}] and
# `deny_names`). Owner: WP-core. Rule ids are reported, values never.
use strict;
use warnings;

sub _entropy {
    my ($s) = @_;
    my %c;
    $c{$_}++ for split //, $s;
    my $n = length $s or return 0;
    my $h = 0;
    for my $v (values %c) { my $p = $v / $n; $h -= $p * log($p) / log(2) }
    return $h;
}

sub _matches {
    my ($text, $r) = @_;
    my @spans;
    while ($text =~ /$r->{re}/g) {
        my ($s, $e) = ($-[0], $+[0]);
        last if $e == $s && !defined pos($text);
        if ($e == $s) { pos($text) = $e + 1; next }
        # Only the value: not the boundary characters a lead or trail group matched; the
        # trailing one is left for the next match, so two values one comma apart both hit.
        $s = $+[1] if $r->{lead} && defined $+[1];
        if ($r->{trail} && defined $-[$#+] && $-[$#+] > $s) { $e = $-[$#+]; pos($text) = $e }
        next if $e <= $s;
        my $m = substr($text, $s, $e - $s);
        next if defined $r->{min_entropy} && _entropy($m) < $r->{min_entropy};
        push @spans, [$s, $e];
    }
    return @spans;
}

# scan(text) -> [{rule, class, count}] (no values)
sub scan {
    my ($text) = @_;
    return [] unless defined $text && $text ne '';
    my @hits;
    for my $r (@{ spec::secret_rules() }) {
        my @s = _matches($text, $r);
        push @hits, { rule => $r->{id}, class => $r->{class}, count => scalar @s } if @s;
    }
    return \@hits;
}

sub has_hard { return scalar grep { $_->{class} eq 'HARD' } @{ $_[0] || [] } }

# redact(text [, classes]) -> (text with each hit replaced by [redacted:<rule>], \@hits)
# Every selected rule runs on the text as given, as scan() does, so the copy and the gate
# agree (RRP-02): a rule applied to another rule's output can miss, e.g. key-value
# rewrites `csrftoken=…` first and the cookie rule then no longer sees the header's
# later pairs. Overlapping or touching spans merge (labelled by the one that starts
# first), then each merged span is replaced once, right to left.
sub redact {
    my ($text, $only) = @_;
    my %only = map { $_ => 1 } @{ $only || [] };
    my (@hits, @spans);
    for my $r (@{ spec::secret_rules() }) {
        next if %only && !$only{ $r->{class} };
        my @s = _matches($text, $r);
        next unless @s;
        push @hits, { rule => $r->{id}, class => $r->{class}, count => scalar @s };
        push @spans, map { [$_->[0], $_->[1], $r->{id}] } @s;
    }
    my @merged;
    for my $sp (sort { $a->[0] <=> $b->[0] || $b->[1] <=> $a->[1] } @spans) {
        if (@merged && $sp->[0] <= $merged[-1][1]) {
            $merged[-1][1] = $sp->[1] if $sp->[1] > $merged[-1][1];
            next;
        }
        push @merged, [@$sp];
    }
    for my $sp (reverse @merged) {
        substr($text, $sp->[0], $sp->[1] - $sp->[0]) = "[redacted:$sp->[2]]";
    }
    return ($text, \@hits);
}

# The path as given and, when a symlink anywhere on the way makes it differ, its real
# target. The name gates run on both forms, so a harmless-named link cannot copy a
# deny-listed file or a transcript (PRIV-02: tasks/<id>.output links to a subagent
# transcript; notes.txt -> .netrc). A target that passes the gate may be followed.
sub _forms {
    my ($path) = @_;
    return () unless defined $path && $path ne '';
    my @f = ($path);
    my $real = eval { util::real_path($path) };
    push @f, $real if defined $real && $real ne $path;
    return @f;
}

sub _denied_base {
    my ($path) = @_;
    my $b = util::basename($path);
    my $deny = spec::deny_names();
    return 0 if grep { $b =~ $_ } @{ spec::deny_except() || [] };
    return (grep { $b =~ $_ } @$deny) ? 1 : 0;
}

sub denied_name {
    my ($path) = @_;
    for my $p (_forms($path)) { return 1 if _denied_base($p) }
    return 0;
}

# The Claude Code config folder (CLAUDE_CONFIG_DIR, else ~/.claude) as given and real.
sub _config_dirs {
    my $cd = eval { settings::config_dir() };
    return () unless defined $cd && $cd ne '';
    $cd =~ s{/+\z}{};
    my $real = eval { util::real_path($cd) };
    return grep { defined && $_ ne '' } ($cd, (defined $real && $real ne $cd ? $real : ()));
}

sub _never {
    my ($p) = @_;
    if ($p =~ /\.jsonl\z/i) {
        return 1 if $p =~ m{/\.claude/projects/};
        for my $cd (_config_dirs()) { return 1 if index($p, "$cd/projects/") == 0 }
    }
    return 1 if util::basename($p) =~ /^(environ|env\.(txt|dump|out))$/i;
    return 0;
}

# Never copied: transcripts and session JSONL (any *.jsonl under <config dir>/projects/),
# environment dumps; checked on the path and on its real target.
sub never_copy {
    my ($path) = @_;
    for my $p (_forms($path)) { return 1 if _never($p) }
    return 0;
}

sub is_log_or_json {
    my ($path) = @_;
    return util::basename($path) =~ /\.(log|json|jsonl|ndjson|out|output)$/i ? 1 : 0;
}

our $SCAN_MAX = 12 * 1024 * 1024;

# classify_file(path) -> (copy|redact|withhold, \@hits, $scanned): the third value is the
# file's bytes as scanned (copy and redact only), so a caller can write exactly what the
# gate read rather than read the file again (bytes appended in between were never
# scanned). A file larger than one scan reads is withheld as `too-large` (RRP-06): the
# part past the scan was never looked at.
sub classify_file {
    my ($path) = @_;
    return ('withhold', [{ rule => 'deny-name', class => 'HARD', count => 1 }]) if denied_name($path) || never_copy($path);
    my $raw = util::read_file($path, $SCAN_MAX + 1);
    return ('withhold', [{ rule => 'unreadable', class => 'HARD', count => 1 }]) unless defined $raw;
    return ('withhold', [{ rule => 'too-large', class => 'HARD', count => 1 }]) if length($raw) > $SCAN_MAX;
    my $hits = scan($raw);
    return ('copy', [], $raw) unless @$hits;
    return ('redact', $hits, $raw) if is_log_or_json($path);
    return ('withhold', $hits) if has_hard($hits);
    return ('redact', $hits, $raw);
}

sub rule_ids { return join(',', map { $_->{rule} } @{ $_[0] || [] }) }

1;

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
sub redact {
    my ($text, $only) = @_;
    my %only = map { $_ => 1 } @{ $only || [] };
    my @hits;
    for my $r (@{ spec::secret_rules() }) {
        next if %only && !$only{ $r->{class} };
        my @s = _matches($text, $r);
        next unless @s;
        push @hits, { rule => $r->{id}, class => $r->{class}, count => scalar @s };
        for my $sp (reverse @s) {
            substr($text, $sp->[0], $sp->[1] - $sp->[0]) = "[redacted:$r->{id}]";
        }
    }
    return ($text, \@hits);
}

sub denied_name {
    my ($path) = @_;
    my $b = util::basename($path);
    return (grep { $b =~ $_ } @{ spec::deny_names() }) ? 1 : 0;
}

# Never copied: transcripts, session JSONL, environment dumps.
sub never_copy {
    my ($path) = @_;
    return 1 if $path =~ m{/\.claude/projects/} && $path =~ /\.jsonl$/;
    return 1 if util::basename($path) =~ /^(environ|env\.(txt|dump|out))$/i;
    return 0;
}

sub is_log_or_json {
    my ($path) = @_;
    return util::basename($path) =~ /\.(log|json|jsonl|ndjson|out|output)$/i ? 1 : 0;
}

# classify_file(path) -> (copy|redact|withhold, \@hits)
sub classify_file {
    my ($path) = @_;
    return ('withhold', [{ rule => 'deny-name', class => 'HARD', count => 1 }]) if denied_name($path) || never_copy($path);
    my $raw = util::read_file($path, 12 * 1024 * 1024);
    return ('withhold', [{ rule => 'unreadable', class => 'HARD', count => 1 }]) unless defined $raw;
    my $hits = scan($raw);
    return ('copy', []) unless @$hits;
    return ('redact', $hits) if is_log_or_json($path);
    return ('withhold', $hits) if has_hard($hits);
    return ('redact', $hits);
}

sub rule_ids { return join(',', map { $_->{rule} } @{ $_[0] || [] }) }

1;

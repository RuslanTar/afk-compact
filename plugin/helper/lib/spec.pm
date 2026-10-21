package spec;
# lib/spec.pm: the spec literals (assets/handoff-spec.json, extracted by tools/build
# from the ```json spec-literals block of assets/handoff-spec.md; BUILD-PLAN §3.4).
# The helper reads headings, marker grammar, verdicts and the secret rule set only
# from here; nothing below hard-codes a heading or a regex. Owner: WP-core.
use strict;
use warnings;

my $SPEC;
my %RE;

sub load {
    return $SPEC if $SPEC;
    my $path = ctx::asset_path('handoff-spec.json');
    my $raw = util::read_file($path);
    die "spec: assets/handoff-spec.json missing\n" unless defined $raw;
    my $s = jsonc::decode($raw);
    die "spec: not an object\n" unless ref $s eq 'HASH';
    $SPEC = $s;
    return $SPEC;
}

sub get {
    my ($key) = @_;
    my $s = load();
    die "spec: key $key missing\n" unless exists $s->{$key};
    return $s->{$key};
}

sub has { my $s = eval { load() }; return $s && exists $s->{$_[0]} ? 1 : 0 }

# Compiled regex for a string key (marker_re, sentinel_re, instr_marker_re, fold_line_re)
sub re {
    my ($key) = @_;
    return $RE{$key} if $RE{$key};
    my $src = get($key);
    die "spec: $key is not a string\n" if ref $src;
    my $re = eval { qr/$src/ };
    die "spec: $key does not compile\n" unless $re;
    $RE{$key} = $re;
    return $re;
}

sub list {
    my ($key) = @_;
    my $v = has($key) ? get($key) : [];
    return ref $v eq 'ARRAY' ? @$v : ();
}

# Secret rules: [{id, class: HARD|WARN, re, min_entropy?}]; compiled once.
my $RULES;
sub secret_rules {
    return $RULES if $RULES;
    my $raw = get('secret_rules');
    my @rules = ref $raw eq 'HASH' ? @{ $raw->{rules} // [] } : ref $raw eq 'ARRAY' ? @$raw : ();
    my @out;
    for my $r (@rules) {
        next unless ref $r eq 'HASH' && defined $r->{re} && defined $r->{id};
        my $src = $r->{re};
        my $re = eval { qr/$src/ } or next;
        push @out, { id => $r->{id}, class => uc($r->{class} // 'WARN'), re => $re,
                     min_entropy => $r->{min_entropy} };
    }
    $RULES = \@out;
    return $RULES;
}

# Deny-listed file names: regexes over the basename. `deny_names` sits beside or
# inside `secret_rules` (BUILD-PLAN §3.4 "plus deny_names").
my $DENY;
sub deny_names {
    return $DENY if $DENY;
    my @src;
    my $sr = has('secret_rules') ? get('secret_rules') : undef;
    push @src, @{ $sr->{deny_names} } if ref $sr eq 'HASH' && ref $sr->{deny_names} eq 'ARRAY';
    push @src, list('deny_names');
    my @out;
    for my $d (@src) {
        my $s = ref $d eq 'HASH' ? $d->{re} : $d;
        next unless defined $s;
        my $re = eval { qr/$s/ } or next;
        push @out, $re;
    }
    $DENY = \@out;
    return $DENY;
}

1;

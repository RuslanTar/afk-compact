package spec;
# lib/spec.pm: the spec literals (assets/handoff-spec.json, extracted by tools/build
# from the ```json spec-literals block of assets/handoff-spec.md).
# The helper reads headings, marker grammar, verdicts and the secret rule set only
# from here; nothing below hard-codes a heading or a regex.
use strict;
use warnings;
use utf8;

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
        # Boundary groups (PRIV-08): a rule written `(^|[^...])body` or `body($|[^...])` matches
        # the character beside the value too; `lead`/`trail` say so, and a hit covers only the
        # value, so redaction keeps the quote, space or newline beside it.
        push @out, { id => $r->{id}, class => uc($r->{class} // 'WARN'), re => $re,
                     min_entropy => $r->{min_entropy},
                     lead => ($src =~ /\A\(\^\|\[\^/ ? 1 : 0),
                     trail => ($src =~ /\(\$\|\[\^(?:\\.|[^\]\\])*\]\)\z/ ? 1 : 0) };
    }
    $RULES = \@out;
    return $RULES;
}

# Deny-listed file names, matched against the basename. `deny_names` sits beside or
# inside `secret_rules`: a list of regexes, or the
# spec-literals form {globs: [...], except_globs: [...]} (`*` and `?` within one name).
my ($DENY, $DENY_EXCEPT);
sub _glob_re {
    my ($g) = @_;
    my $r = join '', map { $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta($_) } split /([*?])/, $g;
    return qr/\A$r\z/;
}
sub _name_re {
    my ($d) = @_;
    return _glob_re($d->{glob}) if ref $d eq 'HASH' && defined $d->{glob};
    my $s = ref $d eq 'HASH' ? $d->{re} : $d;
    return undef unless defined $s && !ref $s;
    return eval { qr/$s/ };
}
sub deny_names {
    return $DENY if $DENY;
    my (@src, @exc);
    my $sr = has('secret_rules') ? get('secret_rules') : undef;
    push @src, @{ $sr->{deny_names} } if ref $sr eq 'HASH' && ref $sr->{deny_names} eq 'ARRAY';
    my $dn = has('deny_names') ? get('deny_names') : undef;
    if (ref $dn eq 'ARRAY') {
        push @src, @$dn;
    } elsif (ref $dn eq 'HASH') {
        push @src, map { { glob => $_ } } @{ $dn->{globs} || [] };
        push @exc, map { { glob => $_ } } @{ $dn->{except_globs} || [] };
    }
    $DENY = [grep { defined } map { _name_re($_) } @src];
    $DENY_EXCEPT = [grep { defined } map { _name_re($_) } @exc];
    return $DENY;
}
sub deny_except { deny_names(); return $DENY_EXCEPT }

1;

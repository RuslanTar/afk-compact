package skills::spec;
# lib/skills/spec.pm: reads assets/handoff-spec.json (BUILD-PLAN §3.4), the only
# source of heading literals, vocabularies and marker grammar for this code.
# Shapes are normalised defensively; the §3.4 key list fixes names only.
use strict;
use warnings;
use skills::util;
use skills::ctx;

my $SPEC;
sub load {
    return $SPEC if $SPEC;
    my $path = skills::ctx::plugin_root() . '/assets/handoff-spec.json';
    my $t = skills::util::read_file($path);
    die "spec-missing\n" unless defined $t;
    my $s = eval { skills::util::json_decode($t) };
    die "spec-invalid\n" unless ref $s eq 'HASH';
    $SPEC = $s;
    return $SPEC;
}

sub available { return eval { load(); 1 } ? 1 : 0 }

# A heading literal → {level, name, literal}
sub _heading {
    my ($h) = @_;
    $h = $h->{heading} // $h->{literal} // $h->{name} if ref $h eq 'HASH';
    return undef unless defined $h && !ref $h;
    my ($hashes, $name) = $h =~ /\A(#*)\s*(.*?)\s*\z/;
    return undef if $name eq '' || $name =~ /\A</;    # the "# <title>" placeholder
    my $level = length($hashes) || 2;
    return { level => $level, name => $name, literal => ('#' x $level) . ' ' . $name };
}

sub _list { my ($v) = @_; return ref $v eq 'ARRAY' ? $v : (defined $v ? [$v] : []) }

# Ordered main sections (level 2) without the title.
sub sections_main {
    my $s = load();
    return [ grep { defined } map { _heading($_) } @{ _list($s->{sections_main}) } ];
}

sub sections_location {
    my $s = load();
    return [ grep { defined } map { my $h = _heading($_); $h->{level} = 3 if $h && $h->{level} < 3; $h ? { %$h, literal => '### ' . $h->{name} } : undef } @{ _list($s->{sections_location}) } ];
}

# Section name => [none-form strings], for the sections that have one.
sub none_forms {
    my $s = load();
    my $v = $s->{none_forms_handoff};
    my %out;
    if (ref $v eq 'HASH') {
        for my $k (keys %$v) {
            my $h = _heading($k) or next;
            $out{ $h->{name} } = [ grep { !ref } @{ _list($v->{$k}) } ];
        }
    } elsif (ref $v eq 'ARRAY') {
        for my $e (@$v) {
            next unless ref $e eq 'HASH';
            my $h = _heading($e->{section} // '') or next;
            push @{ $out{ $h->{name} } }, grep { !ref } @{ _list($e->{form} // $e->{forms}) };
        }
    }
    return \%out;
}

# All none-form strings (any section), for "fixed none-forms" exclusions.
sub none_strings {
    my $nf = none_forms();
    my @all = map { @$_ } values %$nf;
    my $c = load()->{none_forms_compaction};
    push @all, grep { !ref } @{ _list(ref $c eq 'HASH' ? [ map { @{ _list($_) } } values %$c ] : $c) };
    return \@all;
}

sub regex {
    my ($key) = @_;
    my $v = load()->{$key};
    return undef unless defined $v && !ref $v;
    my $re = eval { qr/$v/ };
    return $re;
}

sub marker_re   { return regex('marker_re') }
sub sentinel_re { return regex('sentinel_re') }
sub fold_line_re { return regex('fold_line_re') }

# Outward / destructive command classes (WATCH D-03) → [{class, re}]
sub outward_classes {
    my $v = load()->{outward_classes};
    my @out;
    my $add = sub {
        my ($class, $pat) = @_;
        for my $p (@{ _list($pat) }) {
            next if ref $p || !defined $p || $p eq '';
            my $re = eval { qr/$p/i } or next;
            push @out, { class => $class, re => $re };
        }
    };
    if (ref $v eq 'HASH') {
        $add->($_, $v->{$_}) for sort keys %$v;
    } elsif (ref $v eq 'ARRAY') {
        for my $e (@$v) {
            next unless ref $e eq 'HASH';
            $add->($e->{id} // $e->{class} // 'outward', $e->{re} // $e->{patterns} // $e->{pattern});
        }
    }
    return \@out;
}

# Optional section caps {name => chars}; not in the §3.4 key list yet.
sub section_caps {
    my $v = load()->{section_caps};
    my %out;
    if (ref $v eq 'HASH') {
        for my $k (keys %$v) { my $h = _heading($k) or next; $out{ $h->{name} } = $v->{$k} if !ref $v->{$k} && $v->{$k} =~ /\A\d+\z/ }
    }
    return \%out;
}

sub restart_classes { return _list(load()->{restart_classes}) }

1;

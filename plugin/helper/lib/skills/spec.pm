package skills::spec;
# lib/skills/spec.pm: reads assets/handoff-spec.json, the only
# source of heading literals, vocabularies and marker grammar for this code.
# Shapes are normalised defensively; the key list fixes names only.
use strict;
use warnings;
use utf8;
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

# Fail closed on a key this code needs: need('a', 'b.c') dies
# "spec-missing <key>" when a key (dotted for a nested object) is absent or empty.
sub need {
    my (@keys) = @_;
    my $s = load();
    for my $k (@keys) {
        my $v = $s;
        for my $part (split /\./, $k) {
            $v = ref $v eq 'HASH' ? $v->{$part} : undef;
            last unless defined $v;
        }
        my $empty = !defined $v || (!ref $v && $v eq '') || (ref $v eq 'ARRAY' && !@$v) || (ref $v eq 'HASH' && !%$v);
        die "spec-missing $k\n" if $empty;
    }
    return 1;
}

# The value of a key, dotted for a nested object (need() it first where it is required).
sub get {
    my ($k) = @_;
    my $v = load();
    for my $part (split /\./, $k) { $v = ref $v eq 'HASH' ? $v->{$part} : undef; return undef unless defined $v }
    return $v;
}

# A regex from a string key (dotted), compiled once per call; undef when absent or bad.
sub regex_at {
    my ($k) = @_;
    my $v = get($k);
    return undef unless defined $v && !ref $v && $v ne '';
    return eval { qr/$v/ };
}

# {blocking => {id => 1}, advisory => {id => 1}, repo_mode_only => {id => 1}} (lint_ids).
sub lint_ids {
    my $v = get('lint_ids');
    my %out;
    for my $k (qw(blocking advisory repo_mode_only)) {
        $out{$k} = { map { $_ => 1 } grep { defined && !ref } @{ _list(ref $v eq 'HASH' ? $v->{$k} : undef) } };
    }
    return \%out;
}

# private_path_classes -> [{id, re}] (the `private-path` patterns).
sub private_path_classes {
    my @out;
    for my $e (@{ _list(get('private_path_classes')) }) {
        next unless ref $e eq 'HASH' && defined $e->{re} && !ref $e->{re};
        my $re = eval { qr/$e->{re}/ } or next;
        push @out, { id => $e->{id} // 'private', re => $re };
    }
    return \@out;
}

# frontmatter_keys_<kind> as a list (handoff, copy, export).
sub frontmatter_keys { my ($kind) = @_; return [ grep { defined && !ref } @{ _list(get("frontmatter_keys_$kind")) } ] }

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

# The none-forms as patterns. The spec block writes each one as an anchored
# regex (`^none stated$`); any other entry is matched as a literal line.
sub none_res {
    my @out;
    for my $f (@{ none_strings() }) {
        next unless defined $f && $f ne '';
        my $re = $f =~ /\A\^/ ? eval { qr/$f/ } : qr/\A\Q$f\E\z/;
        push @out, $re if $re;
    }
    return \@out;
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
sub id_range_re { return regex('id_range_re') }
sub time_re     { return regex('time_re') }

# claim_tags.verified_re (the `[verified HH:MM: <cmd>]` tag).
sub verified_re {
    my $t = load()->{claim_tags};
    my $v = ref $t eq 'HASH' ? $t->{verified_re} : undef;
    return undef unless defined $v && !ref $v;
    return eval { qr/$v/ };
}

# One clutter class by id → {re, max_lines, min_run}, or undef when the block
# has no such class. List form [{id, re, max_lines?, min_run?}] or {id => re}.
sub clutter_class {
    my ($id) = @_;
    my $v = load()->{clutter_classes};
    my $e;
    if (ref $v eq 'ARRAY') {
        ($e) = grep { ref $_ eq 'HASH' && ($_->{id} // '') eq $id } @$v;
    } elsif (ref $v eq 'HASH' && defined $v->{$id}) {
        $e = ref $v->{$id} eq 'HASH' ? $v->{$id} : { re => $v->{$id} };
    }
    return undef unless $e && defined $e->{re} && !ref $e->{re};
    my $re = eval { qr/$e->{re}/ } or return undef;
    my %c = (re => $re);
    for my $k (qw(max_lines min_run)) { $c{$k} = $e->{$k} if defined $e->{$k} && $e->{$k} =~ /\A\d+\z/ }
    return \%c;
}

# Outward / destructive command classes → [{class, re}]
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

# lint_texts: {id => {why, fix}} for the publish lint's `  why: … · fix: …`
# lines; {} when the spec has no such key (an older asset: no why lines).
sub lint_texts {
    my $v = get('lint_texts');
    return {} unless ref $v eq 'HASH';
    my %out;
    for my $id (keys %$v) {
        my $e = $v->{$id};
        next unless ref $e eq 'HASH' && defined $e->{why} && !ref $e->{why} && defined $e->{fix} && !ref $e->{fix};
        $out{$id} = { why => $e->{why}, fix => $e->{fix} };
    }
    return \%out;
}

# acuity_re: the Acuity field of Resume here, group 1 the word; undef when absent.
sub acuity_re { return regex('acuity_re') }

# The Acuity words in rising order (stable < watch < unstable): the spec's acuity_words.
sub acuity_words {
    my $v = get('acuity_words');
    my @w = grep { defined && !ref } @{ _list($v) };
    return @w ? \@w : [qw(stable watch unstable)];
}

# Section caps {name => chars} (`section_caps`, keys are the heading literals).
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

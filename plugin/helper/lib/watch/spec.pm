package watch::spec;
# lib/watch/spec.pm: read the spec-literals block (assets/handoff-spec.json,
# BUILD-PLAN §3.4). Owner: WP-watch. The watcher hard-codes no heading and no
# class regex: every list comes from the spec. A missing key gives an empty
# list, and the metric that needs it is logged as null.
use strict;
use warnings;

sub list {
    my ($spec, $key) = @_;
    my $v = $spec->{$key};
    return () unless defined $v;
    if (ref $v eq 'ARRAY') {
        return map { ref $_ eq 'HASH' ? ($_->{literal} // $_->{heading} // $_->{text} // ()) : $_ }
               grep { defined } @$v;
    }
    if (ref $v eq 'HASH') { return map { $v->{$_} } sort keys %$v }
    return ($v);
}

# Named regex classes: accepts {id: re}, [{id|class|name|rule, re|regex}] or [[id, re]].
# Returns [[id, qr]], skipping entries whose regex does not compile.
sub classes {
    my ($spec, $key) = @_;
    my $v = $spec->{$key};
    my @pairs;
    if (ref $v eq 'HASH') {
        @pairs = map { [$_, $v->{$_}] } sort keys %$v;
    } elsif (ref $v eq 'ARRAY') {
        for my $e (@$v) {
            if (ref $e eq 'HASH') {
                my $id = $e->{id} // $e->{class} // $e->{name} // $e->{rule};
                my $re = $e->{re} // $e->{regex} // $e->{pattern};
                push @pairs, [$id, $re] if defined $id && defined $re;
            } elsif (ref $e eq 'ARRAY' && @$e >= 2) {
                push @pairs, [$e->[0], $e->[1]];
            }
        }
    }
    my @out;
    for my $p (@pairs) {
        next if ref $p->[1] || !defined $p->[0] || ref $p->[0];
        my $rx = compile($p->[1], 'm');
        push @out, [$p->[0], $rx] if $rx;
    }
    return \@out;
}

sub compile {
    my ($re, $flags) = @_;
    return undef unless defined $re && !ref $re && length $re;
    $flags ||= '';
    my $rx = eval { $flags eq 'm' ? qr/$re/m : qr/$re/ };
    return $rx;
}

sub regex {
    my ($spec, $key) = @_;
    my $v = $spec->{$key};
    $v = $v->[0] if ref $v eq 'ARRAY';
    return compile($v);
}

# Secret rule ids -> class (HARD/WARN), from `secret_rules`.
sub secret_classes {
    my ($spec) = @_;
    my %c;
    my $v = $spec->{secret_rules};
    $v = $v->{rules} if ref $v eq 'HASH' && ref $v->{rules} eq 'ARRAY';
    if (ref $v eq 'ARRAY') {
        for my $e (@$v) {
            next unless ref $e eq 'HASH' && defined $e->{id};
            $c{$e->{id}} = uc($e->{class} // '');
        }
    }
    return \%c;
}

sub alert_text {
    my ($spec, $rule) = @_;
    my $t = $spec->{alert_texts};
    return undef unless ref $t eq 'HASH';
    my $v = $t->{$rule};
    return (defined $v && !ref $v) ? $v : undef;
}

1;

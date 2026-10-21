package detect;
# lib/detect.pm: marker/sentinel detector, normalized body and verdict (MOD-SPEC
# §5.1, §2.2). Owner: WP-core. Grammar and headings come from the spec literals.
#
# Normalized body: strip the head parts (a `This session is being continued…`
# line, a <tools-used-before-summary>…</tools-used-before-summary> block, a
# `Summary:` line, a `<summary>` tag, and blank lines between them), cut at the
# last `</summary>` when present, else cut installed-message trailers
# (spec `copy_trailers`, canary-baseline `copy_trailers`), trim trailing blank
# lines; line ends `\n`. Marker: anchored grammar in the first 5 body lines.
# Sentinel: the last 3 non-blank lines.
use strict;
use warnings;

my @TRAILERS;
my $TRAILERS_LOADED;
sub _trailers {
    return @TRAILERS if $TRAILERS_LOADED;
    $TRAILERS_LOADED = 1;
    my @src = spec::list('copy_trailers');
    my $raw = util::read_file(ctx::asset_path('canary-baseline.json'));
    my $b = defined $raw ? eval { jsonc::decode($raw) } : undef;
    push @src, @{ $b->{copy_trailers} } if ref $b eq 'HASH' && ref $b->{copy_trailers} eq 'ARRAY';
    for my $t (@src) {
        my $s = ref $t eq 'HASH' ? $t->{re} : $t;
        next unless defined $s && $s ne '';
        my $re = eval { qr/$s/ } or next;
        push @TRAILERS, $re;
    }
    return @TRAILERS;
}

sub _chars {
    my ($t) = @_;
    $t = '' unless defined $t;
    if (!utf8::is_utf8($t)) { my $c = $t; $t = $c if utf8::decode($c) }
    return $t;
}

# normalize(text) -> (\@body_lines, $normalized)
sub normalize {
    my ($text) = @_;
    $text = _chars($text);
    $text =~ s/\r\n?/\n/g;
    my @l = split /\n/, $text, -1;
    my $i = 0;
    while ($i < @l) {
        my $x = $l[$i];
        if ($x =~ /^\s*$/) { $i++; next }
        if ($x =~ /^This session is being continued/) { $i++; next }
        if ($x =~ /^\s*<tools-used-before-summary>/) {
            while ($i < @l && $l[$i] !~ m{</tools-used-before-summary>}) { $i++ }
            $i++;
            next;
        }
        if ($x =~ /^\s*Summary:\s*$/) { $i++; next }
        if ($x =~ /^\s*<summary>(.*)$/) {
            my $rest = $1;
            if ($rest =~ /\S/) { $l[$i] = $rest; last }
            $i++;
            next;
        }
        last;
    }
    my @b = @l[$i .. $#l];
    my $cut;
    for (my $j = $#b; $j >= 0; $j--) {
        if ($b[$j] =~ m{^(.*?)</summary>}) {
            my $before = $1;
            $cut = 1;
            splice(@b, $j);
            push @b, $before if $before =~ /\S/;
            last;
        }
    }
    if (!$cut && (my @tr = _trailers())) {
        my $j = $#b;
        while ($j >= 0) {
            if ($b[$j] =~ /^\s*$/) { $j--; next }
            last unless grep { $b[$j] =~ $_ } @tr;
            splice(@b, $j);
            $j--;
        }
    }
    pop @b while @b && $b[-1] =~ /^\s*$/;
    return (\@b, join("\n", @b));
}

sub _rstrip { my $s = $_[0]; $s =~ s/\s+$//; return $s }

# scan(text) -> {lines, normalized, sha256, marker_line, nonce, scope,
#   sentinel_from_end, sentinel_nonce, has_main_heading, chars}
sub scan {
    my ($text) = @_;
    my ($b, $norm) = normalize($text);
    my $mre = spec::re('marker_re');
    my $sre = spec::re('sentinel_re');
    my %r = (lines => $b, normalized => $norm, chars => length($norm));
    my $n = @$b < 5 ? scalar @$b : 5;
    for my $j (0 .. $n - 1) {
        my $x = _rstrip($b->[$j]);
        if ($x =~ $mre) {
            @r{qw(marker_line nonce scope)} = ($j + 1, $1, $2);
            last;
        }
    }
    my $k = 0;
    for (my $j = $#$b; $j >= 0 && $k < 3; $j--) {
        next if $b->[$j] =~ /^\s*$/;
        $k++;
        my $x = _rstrip($b->[$j]);
        if ($x =~ $sre) { @r{qw(sentinel_from_end sentinel_nonce)} = ($k, $1); last }
    }
    my @heads = spec::list('sections_main');
    my $first = $heads[0];
    if (defined $first) {
        $r{has_main_heading} = (grep { index($_, $first) == 0 } @$b) ? 1 : 0;
    }
    return \%r;
}

# verdict(scan, %ctx) -> verdict string (first match of the MOD-SPEC §5.1 table)
#   ctx: precomputed (bool), scope (main|sub|unknown), dispatch_nonce (expected),
#        marker_has_record (0 = our marker without any dispatch record),
#        marker_earlier (1 = the marker's nonce belongs to an earlier dispatch)
sub verdict {
    my ($s, %c) = @_;
    my $m = defined $s->{nonce};
    return 'stale' if $c{precomputed};
    if ($m) {
        return 'stale' if defined $c{marker_has_record} && !$c{marker_has_record};
        return 'stale' if $c{marker_earlier};
        return 'stale' if defined $c{dispatch_nonce} && $c{dispatch_nonce} ne $s->{nonce};
    }
    my $scope = $c{scope} // 'unknown';
    if ($scope eq 'sub' && (($m && $s->{scope} eq 'main') || $s->{has_main_heading})) { return 'scope-leak' }
    if ($scope eq 'main' && $m && $s->{scope} eq 'sub') { return 'scope-leak' }
    return 'unshaped' unless $m;
    return 'truncated' unless defined $s->{sentinel_nonce} && $s->{sentinel_nonce} eq $s->{nonce};
    return 'ok-trailer' if $s->{sentinel_from_end} > 1;
    return 'ok';
}

# summary(text, \%ctx) -> {verdict, marker_line, sentinel_from_end, nonce, scope, normalized, sha256, ...}
sub summary {
    my ($text, $dispatch) = @_;
    my %c = ref $dispatch eq 'HASH' ? %$dispatch : ();
    $c{dispatch_nonce} = $c{nonce} if exists $c{nonce} && !exists $c{dispatch_nonce};
    my $s = scan($text);
    $s->{verdict} = verdict($s, %c);
    $s->{sha256} = sha::hex256($s->{normalized});
    return $s;
}

sub verdict_line {
    my ($s, $v) = @_;
    return sprintf('VERDICT %s marker_line=%s sentinel_from_end=%s', $v // $s->{verdict},
                   $s->{marker_line} // '-', $s->{sentinel_from_end} // '-');
}

# instructions(text, sid [, watch]) -> {found, nonce, scope, has_record}
# Unanchored search; the last match counts; ours only with a dispatch record.
sub instructions {
    my ($text, $sid, $watch) = @_;
    $watch //= rc::watch();
    my $re = spec::re('instr_marker_re');
    my %r = (found => 0, has_record => 0);
    return \%r unless defined $text && !ref $text && $text ne '';
    $text = _chars($text);
    my ($nonce, $scope);
    while ($text =~ /$re/g) { ($nonce, $scope) = ($1, $2) }
    return \%r unless defined $nonce;
    $r{found} = 1;
    $r{nonce} = $nonce;
    $r{scope} = $scope;
    $r{has_record} = (defined $watch && defined $sid && -e "$watch/$sid/dispatch/$nonce.json") ? 1 : 0;
    return \%r;
}

# C4 shape class
sub shape_class {
    my ($s) = @_;
    return 'ours' if defined $s->{nonce};
    my $b = $s->{lines} || [];
    return 'numbered' if grep { /^\s*1\.\s+Primary Request/ } @$b;
    return 'headings' if grep { /^#{1,3} / } @$b;
    return 'prose';
}

sub fabricated_check_tokens {
    my ($norm) = @_;
    my $n = 0;
    $n++ while $norm =~ /checked \d\d:\d\d/g;
    $n++ while $norm =~ /\[verified /g;
    return $n;
}

1;

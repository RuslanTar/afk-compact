package detect;
# lib/detect.pm: marker/sentinel detector, normalized body and verdict (MOD-SPEC
# §5.1, §2.2). Owner: WP-core. Grammar and headings come from the spec literals.
#
# Normalized body: strip the head parts (a `This session is being continued…`
# line, a <tools-used-before-summary>…</tools-used-before-summary> block, a closed
# <analysis>…</analysis> block (a PostCompact compact_summary keeps it, 2.1.309), a
# closed <system-reminder>…</system-reminder> block (the installed message wraps the
# tools-used block in it, 2.1.311), a `Summary:` line, a `<summary>` tag, and blank
# lines between them), cut before the first `</summary>` when present, else cut installed-message trailers
# (spec `copy_trailers`, canary-baseline `copy_trailers`), trim trailing blank
# lines. Sentinel after the close tag (MOD-SPEC §5.1, P5-FOLD A1): when the first non-blank
# text after `</summary>` (the rest of that line, else the next non-blank line) matches
# `sentinel_re`, that line is appended as the body's last line and the lines after it
# follow as trailers (listed ones cut, never the moved sentinel); any other first line
# keeps everything after the tag outside the body. Then trim trailing blank
# lines; line ends `\n`; the body lines joined by `\n` plus one final `\n`
# (empty body: empty string), the reading of tests/fixtures/summaries/expected.tsv
# and hooks/lib/normalize.ts. Marker: anchored grammar in the first 5 body lines.
# Sentinel: the last 3 non-blank lines.
use strict;
use warnings;
use utf8;

our @TRAILERS;
our $TRAILERS_LOADED;
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

# normalize(text) -> (\@body_lines, $normalized, $moved): $moved = the body index of a sentinel
# moved from after `</summary>`, else undef
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
        # The summarizer's scratch block that a PostCompact compact_summary keeps before
        # <summary> (Claude Code 2.1.309, idle lab runs 2026-10-23); an unclosed one is body.
        if ($x =~ /^\s*<analysis>/) {
            my $j = $i;
            $j++ while $j < @l && $l[$j] !~ m{</analysis>};
            last if $j >= @l;
            $i = $j + 1;
            next;
        }
        # The reminder block the installed message wraps the tools-used block in (Claude Code
        # 2.1.311, live probe 2026-10-27); an unclosed one is body.
        if ($x =~ /^\s*<system-reminder>/) {
            my $j = $i;
            $j++ while $j < @l && $l[$j] !~ m{</system-reminder>};
            last if $j >= @l;
            $i = $j + 1;
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
    my ($cut, $moved);
    for (my $j = 0; $j <= $#b; $j++) {
        if ($b[$j] =~ m{^(.*?)</summary>(.*)$}) {
            my ($before, $tail) = ($1, $2);
            my @after = (($tail =~ /\S/ ? ($tail) : ()), @b[$j + 1 .. $#b]);
            shift @after while @after && $after[0] =~ /^\s*$/;
            $cut = 1;
            splice(@b, $j);
            push @b, $before if $before =~ /\S/;
            if (@after && _rstrip($after[0]) =~ spec::re('sentinel_re')) {
                pop @b while @b && $b[-1] =~ /^\s*$/;
                $moved = scalar @b;
                push @b, @after;
            }
            last;
        }
    }
    _cut_trailers(\@b, 0) if !$cut;
    _cut_trailers(\@b, $moved + 1) if defined $moved;
    pop @b while @b && $b[-1] =~ /^\s*$/;
    return (\@b, @b ? join("\n", @b) . "\n" : '', $moved);
}

# Cut listed installed-message trailers from the end of the body, never at or above index keep.
sub _cut_trailers {
    my ($b, $keep) = @_;
    my @tr = _trailers() or return;
    my $j = $#$b;
    while ($j >= $keep) {
        if ($b->[$j] =~ /^\s*$/) { $j--; next }
        last unless grep { $b->[$j] =~ $_ } @tr;
        splice(@$b, $j);
        $j--;
    }
}

sub _rstrip { my $s = $_[0]; $s =~ s/\s+$//; return $s }

# scan(text) -> {lines, normalized, sha256, marker_line, nonce, scope,
#   sentinel_from_end, sentinel_nonce, sentinel_place (inside | after-close | undef),
#   has_main_heading, chars, unclosed (see unclosed)}
sub scan {
    my ($text, %o) = @_;
    my ($b, $norm, $moved) = normalize($text);
    my $mre = $o{mre} // spec::re('marker_re');
    my $sre = $o{sre} // spec::re('sentinel_re');
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
        if ($x =~ $sre) {
            @r{qw(sentinel_from_end sentinel_nonce)} = ($k, $1);
            $r{sentinel_place} = (defined $moved && $j == $moved) ? 'after-close' : 'inside';
            last;
        }
    }
    $r{unclosed} = unclosed($b, $r{scope}, $sre);
    my @heads = spec::list('sections_main');
    my $first = $heads[0];
    if (defined $first) {
        $r{has_main_heading} = (grep { index($_, $first) == 0 } @$b) ? 1 : 0;
    }
    return \%r;
}

# unclosed(lines, scope, sentinel_re) -> 1 when no body line is in the sentinel grammar (any
# nonce) and the body holds every section the spec's `unclosed_required` lists for the marker's
# scope (sub, else main), in that order, with text under the last (or after a colon on its heading
# line, as in `## Next steps: 1. ...`): a summary complete
# but for its closing line (0.1.3: 3 of 77 saved summaries, each complete through Next steps);
# else 0
sub unclosed {
    my ($b, $scope, $sre) = @_;
    return 0 if grep { _rstrip($_) =~ $sre } @$b;
    my $req = spec::has('unclosed_required') ? spec::get('unclosed_required') : undef;
    my $heads = ref $req eq 'HASH' ? $req->{ ($scope // '') eq 'sub' ? 'sub' : 'main' } : undef;
    return 0 unless ref $heads eq 'ARRAY' && @$heads;
    my $j = 0;
    for my $h (@$heads) {
        $j++ while $j < @$b && index($b->[$j], $h) != 0;
        return 0 if $j >= @$b;
        $j++;
    }
    return 1 if substr($b->[$j - 1], length $heads->[-1]) =~ /:\s*\S/;
    return (grep { /\S/ } @$b[$j .. $#$b]) ? 1 : 0;
}

# alias_scan(text, name) -> scan() with the marker and sentinel grammar written under a former
# plugin name (owner 2026-10-23 xxxxxxxx-26, "Read-only alias"): the spec's marker_re and
# sentinel_re with the plugin name replaced by `name`. undef when the name is not a plain lower-case
# word or the grammar does not hold the plugin name. Read-only: nothing writes this grammar.
sub alias_scan {
    my ($text, $name) = @_;
    return undef unless defined $name && !ref $name && $name =~ /\A[a-z0-9][a-z0-9-]{0,63}\z/;
    my $brand = ctx::brand();
    return undef unless defined $brand && $brand ne '' && $brand ne $name;
    my %re;
    for my $k (qw(marker_re sentinel_re)) {
        my $src = spec::get($k);
        return undef if ref $src;
        my $i = index($src, $brand);
        return undef if $i < 0;
        substr($src, $i, length $brand) = quotemeta $name;
        $re{$k} = eval { qr/$src/ } or return undef;
    }
    return scan($text, mre => $re{marker_re}, sre => $re{sentinel_re});
}

# acuity(scan) -> the Acuity word of a shaped summary (spec acuity_re, T-TEXT E6), or -
our $ACUITY_RE = '(?:^|· )Acuity: (stable|watch|unstable)\b';
sub acuity {
    my ($s) = @_;
    my $re = spec::has('acuity_re') ? spec::re('acuity_re') : do { my $x = $ACUITY_RE; qr/$x/ };
    for my $l (@{ $s->{lines} || [] }) { return $1 if $l =~ $re }
    return '-';
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
    return ($s->{unclosed} ? 'ok-unclosed' : 'truncated') unless defined $s->{sentinel_nonce} && $s->{sentinel_nonce} eq $s->{nonce};
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

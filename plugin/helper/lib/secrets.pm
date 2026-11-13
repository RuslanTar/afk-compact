package secrets;
# lib/secrets.pm: the shared secret rule set, read from
# the spec literals (`secret_rules`: [{id, class HARD|WARN, re, min_entropy?, skip_paths?}] and
# `deny_names`). Rule ids are reported, values never.
use strict;
use warnings;
use utf8;

sub _entropy {
    my ($s) = @_;
    my %c;
    $c{$_}++ for split //, $s;
    my $n = length $s or return 0;
    my $h = 0;
    for my $v (values %c) { my $p = $v / $n; $h -= $p * log($p) / log(2) }
    return $h;
}

# The sweep's deadline (an epoch ms from util::clock_ms, set with `local` by sweep::run; undef
# = none). scan and redact check it before each rule and every 256 hits, and die with
# $OVER_BUDGET once it has passed, so one large file cannot carry the sweep far past its
# budget (the rest become referenced (budget) rows). A file is written
# only after both passes, so a stop leaves no partial copy. The user's rules (U-06) are checked
# once before their child starts; inside it their own time bound holds (_user_spans).
our $DEADLINE;
our $OVER_BUDGET = "secrets: over the sweep budget\n";
sub _check_deadline { die $OVER_BUDGET if defined $DEADLINE && util::clock_ms() >= $DEADLINE }

sub _matches {
    my ($text, $r) = @_;
    my @spans;
    my $n = 0;
    while ($text =~ /$r->{re}/g) {
        _check_deadline() unless ++$n % 256;
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
        next if $r->{skip_paths} && _path_shaped($text, $s, $e, $m, $r);
        push @spans, [$s, $e];
    }
    return @spans;
}

# 0.1.12 path-shaped runs (a rule with `skip_paths`: cloud-key-bare, high-entropy). Their run
# class holds `/`, so a file path read as one long mixed-case run: a macOS temp folder
# (/var/folders/<2>/<30>/T/...), a Windows temp folder with forward slashes
# (C:/.../AppData/Local/Temp/...) or in its Git Bash form (/c/...), a long project path, and
# the in-repo paths a repo-mode export rewrites to relative ones. A hit is skipped when its
# value splits on `/` into 3 or more non-empty parts, none of which the same rule hits alone
# (so a secret kept as one path part is still a hit), and
#   - it is anchored as a path: it starts with `/` (also after `~`, `X:`, `.` or `..`, which
#     end the run before it), or the text before it back to the last whitespace, quote,
#     bracket or one of = , ; : | starts with `/`, `~/`, `./` or `../` (the rest of a path that
#     a `-`, `.` or `_` cut into runs; looked for within $PATH_LOOKBACK characters); or
#   - it is file-shaped (a relative path): `.` and a 1-8 character letter-or-digit extension
#     follow it directly, or every part is word-like ($WORD_RE: letters with at most 3 trailing
#     digits, or 1-4 digits alone) with entropy under $WORD_MAX_H bits per character (4.1:
#     above the 99th percentile, 4.06, of such parts in project paths the 0.1.11 rule hit;
#     measured against 20,000 random base64 values, it costs none of them).
# What this lets through is itself path-shaped: a value that starts with `/`, or one whose
# parts all read as words, with two or more `/` and no part the rule hits alone (spec §10).
our $PATH_LOOKBACK = 1024;
our $WORD_RE = qr/\A(?:[A-Za-z]+[0-9]{0,3}|[0-9]{1,4})\z/;
our $WORD_MAX_H = 4.1;
sub _path_anchored {
    my ($text, $s) = @_;
    return 1 if substr($text, $s, 1) eq '/';
    my $from = $s > $PATH_LOOKBACK ? $s - $PATH_LOOKBACK : 0;
    my $pre = substr($text, $from, $s - $from);
    my ($tok) = $pre =~ m{([^\s"'`<>()\[\]{},;:=|]*)\z};
    return 0 if $from > 0 && length($tok) == length($pre);
    return $tok =~ m{\A(?:/|~/|\.\.?/)} ? 1 : 0;
}
sub _path_shaped {
    my ($text, $s, $e, $m, $r) = @_;
    return 0 if index($m, '/') < 0;
    my @seg = grep { length } split m{/}, $m;
    return 0 if @seg < 3;
    my $one = { %$r, skip_paths => 0 };
    for my $g (@seg) { return 0 if _matches($g, $one) }
    return 1 if _path_anchored($text, $s);
    return 1 if substr($text, $e, 10) =~ /\A\.[A-Za-z0-9]{1,8}(?![A-Za-z0-9])/;
    for my $g (@seg) { return 0 unless $g =~ $WORD_RE && _entropy($g) < $WORD_MAX_H }
    return 1;
}

# The shipped rules, then the user's secret_extra_rules
# (HARD/WARN regexes as user-hard-<n>/user-warn-<n>; NAME globs in _denied_base). Additive only:
# a user rule can withhold more, never less. Read once per value of the setting.
my %EXTRA;
sub _extra {
    my $r = eval { settings::_current() };
    my $v = ref $r eq 'HASH' && ref $r->{values} eq 'HASH' ? ($r->{values}{secret_extra_rules} // '') : '';
    $EXTRA{$v} //= eval { settings::secret_extra({ values => { secret_extra_rules => $v } }) } || { rules => [], names => [], invalid => [] };
    return $EXTRA{$v};
}
sub rules {
    my @x = map { { id => $_->{id}, class => $_->{class}, re => $_->{re}, min_entropy => undef, lead => 0, trail => 0,
                    user => 1, at => $_->{at} } } @{ _extra()->{rules} };
    return [ @{ spec::secret_rules() }, @x ];
}

# U-06: the user's HARD and WARN rules run in one child with the time bound of lib/userre.pm.
# _user_spans(text, \@user rules) -> ({rule id => [count, [[start, end]…]]}, stopped class); the
# spans of one rule that touch are merged (redact merges them anyway), the count is the match
# count. A rule that is stopped or not run counts as a hit of its class over the whole text:
# scan adds the hit `regex-timeout`, HARD when a HARD rule was among them, else WARN, and redact
# replaces the whole text. So a stopped HARD rule withholds; a stopped WARN rule does what a WARN
# hit does (a HARD-only redaction, as the summary copy's, keeps the text). Only a stopped HARD
# rule ends the run: after a stopped WARN rule the rules after it still run, so a HARD rule
# listed later is not counted as stopped.
our $TIMEOUT_RULE = 'regex-timeout';
sub _user_spans {
    my ($text, $rules) = @_;
    return ({}, '') unless @$rules;
    # the sweep's deadline is checked here, in this process; the child that runs the patterns
    # has its own time bound, so a deadline that passed there is not taken for a stopped rule
    _check_deadline();
    my ($res, $stopped) = userre::run('secret_extra_rules', [map { { re => $_->{re}, at => $_->{at} } } @$rules], sub {
        local $DEADLINE;
        my @s = _matches($text, { re => $_[0]{re}, lead => 0, trail => 0 });
        my @m;
        for my $sp (@s) {
            if (@m && $sp->[0] <= $m[-1][1]) { $m[-1][1] = $sp->[1] if $sp->[1] > $m[-1][1] }
            else { push @m, [@$sp] }
        }
        return (scalar(@s), map { @$_ } @m);
    }, halt => sub { ($rules->[$_[0]]{class} // '') eq 'HARD' }, memo => "spans\0$text", size => length $text);
    my %out;
    for my $i (0 .. $#$rules) {
        my $v = $res->[$i] or next;
        my ($n, @p) = @$v;
        $out{ $rules->[$i]{id} } = [$n, [map { [$p[2 * $_], $p[2 * $_ + 1]] } 0 .. int(@p / 2) - 1]];
    }
    my @un = grep { !$res->[$_] } 0 .. $#$rules;
    return (\%out, (grep { ($rules->[$_]{class} // '') eq 'HARD' } @un) ? 'HARD' : @un ? 'WARN' : '');
}

# scan(text [, lines => 1]) -> [{rule, class, count}] (no values); with `lines`, each hit also has
# lines => [the 1-based numbers of the lines its matches start on, ascending, each once] (0.1.3:
# publish names where a WARN hit is, never what; a stopped rule's hit has none)
sub scan {
    my ($text, %o) = @_;
    return [] unless defined $text && $text ne '';
    my @hits;
    my $all = rules();
    my ($u, $stopped) = _user_spans($text, [grep { $_->{user} } @$all]);
    my $nl = $o{lines} ? _newlines($text) : undef;
    for my $r (@$all) {
        _check_deadline() unless $r->{user};
        my ($n, @s);
        if ($r->{user}) { my $x = $u->{ $r->{id} }; ($n, @s) = $x ? ($x->[0], @{ $x->[1] }) : (0) }
        else { @s = _matches($text, $r); $n = scalar @s }
        next unless $n;
        push @hits, { rule => $r->{id}, class => $r->{class}, count => $n, ($nl ? (lines => _line_numbers($nl, \@s)) : ()) };
    }
    push @hits, { rule => $TIMEOUT_RULE, class => $stopped, count => 1 } if $stopped;
    return \@hits;
}

# _newlines(text) -> [offsets of each newline]; _line_numbers(newlines, [[start, end]...]) -> the
# distinct 1-based line numbers the spans start on, ascending
sub _newlines {
    my ($text) = @_;
    my @nl;
    while ($text =~ /\n/g) { push @nl, $-[0] }
    return \@nl;
}
sub _line_numbers {
    my ($nl, $spans) = @_;
    my %ln;
    for my $sp (@$spans) {
        my ($lo, $hi) = (0, scalar @$nl);
        while ($lo < $hi) { my $m = int(($lo + $hi) / 2); if ($nl->[$m] < $sp->[0]) { $lo = $m + 1 } else { $hi = $m } }
        $ln{ $lo + 1 } = 1;
    }
    return [ sort { $a <=> $b } keys %ln ];
}

sub has_hard { return scalar grep { $_->{class} eq 'HARD' } @{ $_[0] || [] } }

# redact(text [, classes]) -> (text with each hit replaced by [redacted:<rule>], \@hits)
# Every selected rule runs on the text as given, as scan() does, so the copy and the gate
# agree: a rule applied to another rule's output can miss, e.g. key-value
# rewrites `csrftoken=…` first and the cookie rule then no longer sees the header's
# later pairs. Overlapping or touching spans merge, then each merged span is replaced
# once, labelled by the rule that comes first in the spec's list (the most specific:
# `Bearer <JWT>` reads [redacted:jwt]).
sub redact {
    my ($text, $only) = @_;
    my %only = map { $_ => 1 } @{ $only || [] };
    my (@hits, @spans);
    my $rank = 0;
    my $all = rules();
    my ($u, $stopped) = _user_spans($text, [grep { $_->{user} && (!%only || $only{ $_->{class} }) } @$all]);
    for my $r (@$all) {
        $rank++;
        next if %only && !$only{ $r->{class} };
        my ($n, @s);
        if ($r->{user}) { my $x = $u->{ $r->{id} } or next; ($n, @s) = ($x->[0], @{ $x->[1] }) }
        else { _check_deadline(); @s = _matches($text, $r); $n = scalar @s }
        next unless @s;
        push @hits, { rule => $r->{id}, class => $r->{class}, count => $n };
        push @spans, map { [$_->[0], $_->[1], $r->{id}, $rank] } @s;
    }
    if ($stopped) {
        push @hits, { rule => $TIMEOUT_RULE, class => $stopped, count => 1 };
        push @spans, [0, length $text, $TIMEOUT_RULE, 0];
    }
    my @merged;
    for my $sp (sort { $a->[0] <=> $b->[0] || $b->[1] <=> $a->[1] } @spans) {
        if (@merged && $sp->[0] <= $merged[-1][1]) {
            my $m = $merged[-1];
            $m->[1] = $sp->[1] if $sp->[1] > $m->[1];
            @$m[2, 3] = @$sp[2, 3] if $sp->[3] < $m->[3];
            next;
        }
        push @merged, [@$sp];
    }
    return ($text, \@hits) unless @merged;
    # One left-to-right pass: the text between spans and each label are joined once, so the
    # cost is linear in the text (replacing in place copied the tail per span: quadratic).
    my ($at, @out) = (0);
    for my $sp (@merged) {
        push @out, substr($text, $at, $sp->[0] - $at), "[redacted:$sp->[2]]";
        $at = $sp->[1];
    }
    push @out, substr($text, $at);
    my $red = join('', @out);
    # a character string stays one (substr of its ASCII part can come back as bytes)
    utf8::upgrade($red) if utf8::is_utf8($text);
    return ($red, \@hits);
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
    # a user NAME glob withholds whatever the shipped exceptions say (it can only add).
    return 1 if grep { $b =~ $_->{re} } @{ _extra()->{names} };
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
# scanned). A file larger than one scan reads is withheld as `too-large`: the
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

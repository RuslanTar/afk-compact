# cmd/smoke.pl: maintainer-run version smoke.
# smoke [--sid S] [--claude BIN] [--types FILE] [--skip-cli]
# Checks, one line each: `claude plugin validate --strict` and `claude plugin test` on
# this plugin, C8 binary string counts and C9 type-declaration hashes against
# assets/canary-baseline.json. Then `SMOKE PASS <version>` (exit 0; clears smokeDue
# in <watch>/version.json) or `SMOKE FAIL <check>` (exit 1). Never starts a session.
# A check whose input is missing (no claude binary for C8, no type declarations for
# C9) fails: a smoke that could not compare cannot clear smokeDue (AT-M3-14).
# C8 fails only on rare strings (c8_compare): a string the baseline counted a whole number
# of times from 1 to c8.rare_max is rare (_rare, the rule tools/canary-baseline and
# tools/check apply too; plugin-specific: the compaction experiment's flag and env
# variable, CLAUDE_CODE_EXECPATH, the PreCompact stdout notice, the two idle notices),
# and any change of its count fails. Any other string is a common word whose count moves
# with every release: a change prints an `info c8` line and does not fail (AT-M3-14c).
# A baseline without a whole-number rare_max takes every count of 1 or more as rare. A
# count of 0 is never rare: the baseline tool never writes one (it would let C8 pass on the
# string's absence), so a baseline that holds one was edited or is broken; so was one with a
# count for the empty string (count_strings would search for it without end). A baseline with
# no c8 counts, a count for the empty string, a count of 0, or no rare string (rare_max 0, or
# below every count) fails C8 even with --skip-cli (c8_unusable): C8 is never left out, or
# passed with nothing compared, without a FAIL line.
# C8 compares the Claude Code smoke runs against with the one the baseline was recorded
# on (its cc_version), so a version whose counts differ fails C8: 2.1.314 holds the flag
# and env variable less often than 2.1.321 to 2.1.323 and 2.1.325 (the versions measured
# since). The baseline ships in this plugin beside this file (assets/), so smoke only ever
# reads the baseline its own release recorded, the one tools/canary-baseline writes: no
# arm list (the baseline recorded on 2.1.314 had one, read by that release's own smoke).
# C9 reads --types FILE, else the file the running Claude Code wrote when its built-in
# plugin-authoring skill loaded (bundled_types): no version writes declarations into an
# installed plugin, so <plugin>/.claude-plugin/types is not read. That folder is swept a
# few days later, so the missing-declarations message says to load the skill once and
# run smoke again while that session is open.
# --skip-cli (tests) skips the checks that run or read the claude binary: validate,
# test and C8.
use strict;
use warnings;
use utf8;

package cmd_smoke;

sub _claude_bin {
    my ($opt) = @_;
    my $b = $opt->{claude} // $ENV{CLAUDE_CODE_EXECPATH};
    $b = util::which('claude') unless defined $b && $b ne '';
    return undef unless defined $b && -x $b;
    my $real = util::real_path($b);
    if (-l $b) { require Cwd; $real = Cwd::abs_path($b) // $real }
    return $real;
}

sub _version {
    my ($bin) = @_;
    my $base = util::basename($bin // '');
    return $base if $base =~ /^[0-9]+\.[0-9]+\.[0-9]+/;
    return undef unless $bin;
    my $r = util::run([$bin, '--version'], timeout_ms => 20000);
    return ($r->{out} =~ /([0-9]+\.[0-9]+\.[0-9]+\S*)/)[0];
}

# The type declarations Claude Code <ver> wrote when its plugin-authoring skill loaded:
# realpath(($CLAUDE_CODE_TMPDIR || /tmp)/claude-<uid>)/bundled-skills/<ver>/<per-process
# folder>/plugin-authoring/types/claude-code.d.ts whose line 1 is `// Written by Claude
# Code <ver>.`; the newest by mtime (ties: the last name). Only a plain file (not a
# symlink) under a claude-<uid> folder this user owns: a folder another local user made
# first could plant declarations that clear smokeDue. An internal layout, not a public
# interface: when it changes this finds nothing and C9 fails closed.
sub bundled_types {
    my ($ver) = @_;
    return undef unless defined $ver && $ver =~ /^[0-9]+\.[0-9]+\.[0-9]+/ && $ver !~ m{/};
    my $tmp = $ENV{CLAUDE_CODE_TMPDIR};
    $tmp = '/tmp' unless defined $tmp && $tmp ne '';
    my $base = util::real_path("$tmp/claude-$<") // "$tmp/claude-$<";
    my @bs = stat $base;
    return undef unless @bs && -d _ && $bs[4] == $<;
    my $dir = "$base/bundled-skills/$ver";
    my $head = "// Written by Claude Code $ver.";
    my ($best, $best_m);
    for my $n (util::list_dir($dir)) {
        my $f = "$dir/$n/plugin-authoring/types/claude-code.d.ts";
        next if -l $f;
        next unless -f $f;
        open(my $fh, '<:raw', $f) or next;
        my $l1 = <$fh>;
        close $fh;
        next unless defined $l1;
        $l1 =~ s/\r?\n\z//;
        next unless $l1 eq $head;
        my $m = (stat $f)[9] // 0;
        ($best, $best_m) = ($f, $m) if !defined $best_m || $m >= $best_m;
    }
    return $best;
}

# Count non-overlapping occurrences of each string in a big file, 8 MB chunks; a
# match is counted in the round where it ends (tools/canary-baseline counts the same). The
# empty string is never searched (it would match at every place without end): c8_unusable
# refuses a baseline that counts it, so its count stays 0 here.
sub count_strings {
    my ($path, $strings) = @_;
    my %n = map { $_ => 0 } @$strings;
    my $over = 0;
    for (@$strings) { $over = length($_) - 1 if length($_) - 1 > $over }
    open(my $fh, '<:raw', $path) or return undef;
    my $carry = '';
    while (1) {
        my $got = read($fh, my $buf, 8 * 1024 * 1024);
        last unless $got;
        my $data = $carry . $buf;
        my $cl = length $carry;
        for my $s (@$strings) {
            next unless length $s;
            my $pos = 0;
            while (($pos = index($data, $s, $pos)) >= 0) {
                $n{$s}++ if $pos + length($s) > $cl;
                $pos += length $s;
            }
        }
        $carry = $over > 0 ? substr($data, length($data) > $over ? -$over : 0) : '';
    }
    close $fh;
    return \%n;
}

# c8.rare_max as a whole number, or undef when it is missing or malformed (then every count
# of 1 or more is rare).
sub _rare_max {
    my ($c8) = @_;
    my $max = $c8->{rare_max};
    return defined $max && !ref $max && $max =~ /^[0-9]+\z/ ? 0 + $max : undef;
}

# The one definition of a rare count (tools/canary-baseline is_rare, which tools/check uses
# too): a whole number from 1 to rare_max (any whole number from 1 when rare_max is undef).
# A count of 0 is never rare.
sub _rare {
    my ($n, $max) = @_;
    return 0 unless defined $n && !ref $n && $n =~ /^[0-9]+\z/ && $n >= 1;
    return !defined $max || $n <= $max ? 1 : 0;
}

# Why a baseline's c8 part cannot be compared (a text for the FAIL line), or undef: it must be
# an object whose counts hold at least one string, none of them empty, each counted a whole
# number of times, none 0, and at least one of them rare (C8 fails on rare strings only, so with none it compares
# nothing): rare_max 0, or a rare_max below every count, leaves no rare string.
sub c8_unusable {
    my ($c8) = @_;
    return 'no c8 part' unless ref $c8 eq 'HASH';
    my $want = $c8->{counts};
    return 'no c8 counts' unless ref $want eq 'HASH' && %$want;
    return 'a c8 count for an empty string (""), which tools/canary-baseline never writes: an edited or broken baseline'
        if exists $want->{''};
    my @bad = grep { my $n = $want->{$_}; !defined $n || ref $n || $n !~ /^[0-9]+\z/ } sort keys %$want;
    return 'a c8 count that is not a whole number (' . join(', ', map { "\"$_\"" } @bad) . ')' if @bad;
    my @zero = grep { $want->{$_} == 0 } sort keys %$want;
    return (@zero == 1 ? 'a c8 count' : 'c8 counts') . ' of 0 (' . join(', ', map { "\"$_\"" } @zero)
        . '), which tools/canary-baseline never writes: an edited or broken baseline' if @zero;
    my $max = _rare_max($c8);
    return 'no rare string: c8.rare_max is 0' if defined $max && $max == 0;
    return "no rare string: every c8 count is above c8.rare_max $max"
        unless grep { _rare($want->{$_}, $max) } keys %$want;
    return undef;
}

# C8 against the baseline's c8 part (see the header): {ok => 1|0, note, info => [lines]}.
# Rare: every string whose baseline count is rare (_rare); their changes fail, a common
# word's change is one info line.
sub c8_compare {
    my ($c8, $bin) = @_;
    my $want = $c8->{counts};
    my @s = sort keys %$want;
    my $max = _rare_max($c8);
    my $n = count_strings($bin, \@s);
    return { ok => 0, note => "cannot read $bin", info => [] } unless defined $n;
    my (@fail, @info);
    my ($rare, $common) = (0, 0);
    for my $k (@s) {
        my $hard = _rare($want->{$k}, $max);
        $hard ? $rare++ : $common++;
        next if $n->{$k} == $want->{$k};
        my $d = "\"$k\" $want->{$k} -> $n->{$k}";
        if ($hard) { push @fail, $d }
        else { push @info, "info c8 $d (a common word: information only)" }
    }
    my $what = "$rare rare string" . ($rare == 1 ? '' : 's');
    return { ok => 0, note => 'changed: ' . join(', ', @fail), info => \@info } if @fail;
    return { ok => 1, info => \@info,
             note => "$what as recorded; $common common word" . ($common == 1 ? '' : 's') . ' not compared' };
}

# The C9 extraction, same algorithm as tools/canary-baseline: from the first line
# matching start_re, comments stripped, until bracket depth returns to 0 on a line
# ending with `;`; sha256 of the kept lines joined by \n, first 16 hex.
sub decl_hash {
    my ($lines, $start_re) = @_;
    my $re = qr/$start_re/;
    my ($i) = grep { $lines->[$_] =~ $re } 0 .. $#$lines;
    return undef unless defined $i;
    my ($depth, $in_block, @kept) = (0, 0);
    for my $j ($i .. $#$lines) {
        my $l = $lines->[$j];
        if ($in_block) {
            next unless $l =~ s{^.*?\*/}{};
            $in_block = 0;
        }
        $l =~ s{/\*.*?\*/}{}g;
        if ($l =~ s{/\*.*$}{}) { $in_block = 1 }
        $l =~ s{//.*$}{};
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '';
        my $open = () = $l =~ /[\{\(\[]/g;
        my $close = () = $l =~ /[\}\)\]]/g;
        $depth += $open - $close;
        push @kept, $l;
        last if $depth <= 0 && $l =~ /;$/;
    }
    return substr(sha::hex256(join("\n", @kept)), 0, 16);
}

sub run {
    my ($opt) = args::parse(\@_, bools => ['skip-cli'], known => [qw(sid claude types root log-dir)]);
    my $sid = $opt->{sid};
    die "usage: --sid is not a session id\n" if defined $sid && !args::valid_sid($sid);
    rc::init(sid => $sid // 'smoke', writer => 'helper', flags => settings::flags_from($opt));
    my $root = ctx::root();
    my $raw = util::read_file(ctx::asset_path('canary-baseline.json'));
    my $base = defined $raw ? eval { jsonc::decode($raw) } : undef;
    my @lines;
    my $fail;
    my $check = sub { my ($name, $ok, $note) = @_; push @lines, ($ok ? 'ok' : defined $ok ? 'FAIL' : 'skip') . " $name" . (defined $note ? " ($note)" : ''); $fail //= $name if defined $ok && !$ok };
    $check->('baseline', ref $base eq 'HASH' ? 1 : 0, ref $base eq 'HASH' ? "Claude Code $base->{cc_version}" : 'assets/canary-baseline.json missing');
    my $bin = _claude_bin($opt);
    my $ver = _version($bin) // 'unknown';
    if ($opt->{'skip-cli'}) {
        $check->('validate', undef, 'skipped by flag');
        $check->('test', undef, 'skipped by flag');
    } elsif (!$bin) {
        $check->('validate', 0, 'claude binary not found');
    } else {
        my $v = util::run([$bin, 'plugin', 'validate', $root, '--strict'], timeout_ms => 120000);
        $check->('validate', $v->{exit} == 0 ? 1 : 0, "exit $v->{exit}");
        my $t = util::run([$bin, 'plugin', 'test', $root], timeout_ms => 300000);
        $check->('test', $t->{exit} == 0 ? 1 : 0, "exit $t->{exit}");
    }
    if (ref $base eq 'HASH') {
        my $unusable = c8_unusable($base->{c8});
        if (defined $unusable) { $check->('c8', 0, "the baseline has $unusable, so C8 cannot compare") }
        elsif ($opt->{'skip-cli'}) { $check->('c8', undef, 'skipped by flag') }
        elsif (!$bin) { $check->('c8', 0, 'claude binary not found') }
        else {
            my $c = c8_compare($base->{c8}, $bin);
            $check->('c8', $c->{ok}, $c->{note});
            push @lines, @{ $c->{info} };
        }
    }
    if (ref $base eq 'HASH' && ref $base->{c9} eq 'HASH') {
        my $known = $ver =~ /^[0-9]+\.[0-9]+\.[0-9]+/;
        my $tf = $opt->{types} // bundled_types($known ? $ver : undef);
        my $traw = defined $tf && -f $tf ? util::read_file($tf) : undef;
        if (!defined $traw) {
            $check->('c9', 0, defined $opt->{types} ? "no type declarations at $opt->{types}"
                : "no type declarations for Claude Code $ver: type /plugin-authoring once in any Claude Code session, then run smoke again while it is open; or pass --types FILE");
        }
        else {
            my @tl = split /\n/, $traw;
            my ($tv) = ($tl[0] // '') =~ m{^// Written by Claude Code (\S+?)\.?\r?$};
            my @diff;
            for my $spec (@{ $base->{c9}{specs} || [] }) {
                my $h = decl_hash(\@tl, $spec->{start_re});
                push @diff, $spec->{name} unless defined $h && $h eq ($base->{c9}{hashes}{ $spec->{name} } // '');
            }
            $check->('c9', @diff ? 0 : 1, @diff ? 'changed: ' . join(', ', @diff)
                : scalar(@{ $base->{c9}{specs} || [] }) . ' declarations' . (defined $tv ? "; Claude Code $tv types" : ''));
        }
    }
    args::out(@lines);
    my $w = rc::watch();
    if ($fail) {
        rc::emit('smoke_fail', [check => $fail, version => $ver], stream => (defined $sid ? 'classic' : "$w/smoke.classic.jsonl")) if defined $w;
        args::out("SMOKE FAIL $fail");
        return 1;
    }
    if (defined $w) {
        my $vf = "$w/version.json";
        my $vr = util::read_file($vf);
        my $vj = defined $vr ? eval { jsonc::decode($vr) } : undef;
        if (ref $vj eq 'HASH' && exists $vj->{smokeDue}) {
            delete $vj->{smokeDue};
            $vj->{lastSmokePass} = $ver;
            util::write_atomic($vf, jsonc::encode_bytes($vj) . "\n", 0600);
        }
        rc::emit('smoke_pass', [version => $ver], stream => (defined $sid ? 'classic' : "$w/smoke.classic.jsonl"));
    }
    args::out("SMOKE PASS $ver");
    return 0;
}

exit(args::main(\&run, @ARGV));

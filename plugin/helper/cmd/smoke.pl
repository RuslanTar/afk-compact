# cmd/smoke.pl: owner-run version smoke (MOD-SPEC §5.6; BUILD-PLAN §3.1). Owner: WP-core.
# smoke [--sid S] [--claude BIN] [--types FILE] [--skip-cli]
# Checks, one line each: `claude plugin validate --strict` and `claude plugin test` on
# this plugin, C8 binary string counts and C9 type-declaration hashes against
# assets/canary-baseline.json. Then `SMOKE PASS <version>` (exit 0; clears smokeDue
# in <watch>/version.json) or `SMOKE FAIL <check>` (exit 1). Never starts a session.
# A check whose input is missing (no claude binary for C8, no type declarations for
# C9) fails: a smoke that could not compare cannot clear smokeDue (AT-M3-14; F2-9).
# C8 fails only on rare strings and the arm list (c8_compare): a string the baseline
# counted at most c8.rare_max times is rare (plugin-specific: the flag, its env
# variable, the notice texts, the experiment's own arm names), and c8.arm_list is the
# experiment's arm list as the binary writes it; any change of their counts fails. Any
# other string is a common word whose count moves with every release: a change prints
# an `info c8` line and does not fail (AT-M3-14c). A baseline without rare_max treats
# every string as rare.
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
    return $base if $base =~ /^\d+\.\d+\.\d+/;
    return undef unless $bin;
    my $r = util::run([$bin, '--version'], timeout_ms => 20000);
    return ($r->{out} =~ /(\d+\.\d+\.\d+\S*)/)[0];
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
    return undef unless defined $ver && $ver =~ /^\d+\.\d+\.\d+/ && $ver !~ m{/};
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
# match is counted in the round where it ends (tools/canary-baseline counts the same).
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

# C8 against the baseline's c8 part (see the header): {ok => 1|0, note, info => [lines]}.
# Rare: the arm list, and every string whose baseline count is at most rare_max (all of
# them when rare_max is not a whole number); their changes fail, a common word's change
# is one info line.
sub c8_compare {
    my ($c8, $bin) = @_;
    my $want = $c8->{counts};
    my @s = sort keys %$want;
    my $arm = $c8->{arm_list};
    my $max = $c8->{rare_max};
    $max = undef unless defined $max && $max =~ /^\d+\z/;
    return { ok => 0, note => 'the arm list is not counted in the baseline', info => [] }
        if defined $arm && !exists $want->{$arm};
    my $n = count_strings($bin, \@s);
    return { ok => 0, note => "cannot read $bin", info => [] } unless defined $n;
    my $label = sub { defined $arm && $_[0] eq $arm ? 'the arm list' : "\"$_[0]\"" };
    my (@fail, @info);
    my ($rare, $common) = (0, 0);
    for my $k (@s) {
        my $is_arm = defined $arm && $k eq $arm;
        my $hard = $is_arm || !defined $max || $want->{$k} <= $max;
        if (!$is_arm) { $hard ? $rare++ : $common++ }
        next if $n->{$k} == $want->{$k};
        my $d = $label->($k) . " $want->{$k} -> $n->{$k}";
        if ($hard) { push @fail, $d }
        else { push @info, "info c8 $d (a common word: information only)" }
    }
    my $what = "$rare rare string" . ($rare == 1 ? '' : 's') . (defined $arm ? ' and the arm list' : '');
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
    if (ref $base eq 'HASH' && ref $base->{c8} eq 'HASH' && ref $base->{c8}{counts} eq 'HASH') {
        if ($opt->{'skip-cli'}) { $check->('c8', undef, 'skipped by flag') }
        elsif (!$bin) { $check->('c8', 0, 'claude binary not found') }
        else {
            my $c = c8_compare($base->{c8}, $bin);
            $check->('c8', $c->{ok}, $c->{note});
            push @lines, @{ $c->{info} };
        }
    }
    if (ref $base eq 'HASH' && ref $base->{c9} eq 'HASH') {
        my $known = $ver =~ /^\d+\.\d+\.\d+/;
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

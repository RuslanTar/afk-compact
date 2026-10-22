# cmd/smoke.pl: owner-run version smoke (MOD-SPEC §5.6; BUILD-PLAN §3.1). Owner: WP-core.
# smoke [--sid S] [--claude BIN] [--types FILE] [--skip-cli]
# Checks, one line each: `claude plugin validate --strict` and `claude plugin test` on
# this plugin, C8 binary string counts and C9 type-declaration hashes against
# assets/canary-baseline.json. Then `SMOKE PASS <version>` (exit 0; clears smokeDue
# in <watch>/version.json) or `SMOKE FAIL <check>` (exit 1). Never starts a session.
# A check whose input is missing (no claude binary for C8, no type declarations for
# C9) fails: a smoke that could not compare cannot clear smokeDue (AT-M3-14).
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
            my @s = sort keys %{ $base->{c8}{counts} };
            my $n = count_strings($bin, \@s);
            my @diff = grep { !defined $n || $n->{$_} != $base->{c8}{counts}{$_} } @s;
            $check->('c8', @diff ? 0 : 1, @diff ? scalar(@diff) . ' string count(s) differ from the baseline' : scalar(@s) . ' strings');
        }
    }
    if (ref $base eq 'HASH' && ref $base->{c9} eq 'HASH') {
        my $tf = $opt->{types} // "$root/.claude-plugin/types/claude-code.d.ts";
        my $traw = -f $tf ? util::read_file($tf) : undef;
        if (!defined $traw) { $check->('c9', 0, 'no type declarations; load the plugin once to write them') }
        else {
            my @tl = split /\n/, $traw;
            my @diff;
            for my $spec (@{ $base->{c9}{specs} || [] }) {
                my $h = decl_hash(\@tl, $spec->{start_re});
                push @diff, $spec->{name} unless defined $h && $h eq ($base->{c9}{hashes}{ $spec->{name} } // '');
            }
            $check->('c9', @diff ? 0 : 1, @diff ? 'changed: ' . join(', ', @diff) : scalar(@{ $base->{c9}{specs} || [] }) . ' declarations');
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

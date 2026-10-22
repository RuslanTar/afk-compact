package skills::evidence_cmd;
# lib/skills/evidence_cmd.pm: `evidence --stage DIR [--keep P…] [--dispose P…]
# [--clone DIR…]` (HDN §6, TPL §5). Needed-later copies go to
# <bucket>/evidence/<stem>/, disposable ones to today's
# <disposable_root>/<YYYY-MM-DD>/<stem>-evidence/. Caps, secret gate and
# cross-bucket dedupe are the core evidence.copy seam's.
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::cli;
use skills::core;
use skills::stage;
use skills::gitfacts;

our $FILE_MAX  = 10 * 1024 * 1024;
our $TOTAL_MAX = 50 * 1024 * 1024;
our $CLONE_MAX = 50;

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'stage=s', 'keep=s{1,}' => \my @keep, 'dispose=s{1,}' => \my @dispose,
        'clone=s{1,}' => \my @clone);
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('nothing to do') unless @keep || @dispose || @clone;
    my ($dir, $s, $ctx) = skills::stage::open_stage($o->{stage});
    my $refused = skills::core::roots_check($ctx->{settings});
    die skills::cli::refuse($refused) if $refused;

    my $now = skills::util::now();
    my $bucket = $s->{bucket};
    my $keep_dir = "$bucket/evidence/$s->{stem}";
    my $disp_dir = "$ctx->{disposable}/" . skills::util::ymd($now) . "/$s->{stem}-evidence";
    my $index = "$ctx->{watch}/evidence-index.tsv";
    skills::util::mkdir_p($ctx->{watch});
    my $used = 0;
    $used += ($_->{bytes} // 0) for grep { ($_->{status} // '') =~ /\A(copied|redacted)\z/ } @{ skills::stage::evidence_rows($dir) };

    my @jobs = ((map { _expand(keep => $_) } @keep), (map { _expand(dispose => $_) } @dispose));
    for my $c (@clone) { push @jobs, map { [ keep => undef, $_->{label}, $_ ] } _clone_patches($c) }

    my @rows;
    for my $j (@jobs) {
        my ($where, $path, $origin_label, $patch) = @$j;
        my $src = defined $path ? (skills::util::abs_path($path) // $path) : undef;
        my $dest = $where eq 'keep' ? $keep_dir : $disp_dir;
        my $r;
        if ($patch && defined $patch->{bytes}) {
            $r = _gate_patch($patch, $dest, $used);
        } elsif (!defined $src || !-e $src || -d _) {
            $r = { status => 'missing', copy => undef, bytes => 0, sha256 => '' };
        } else {
            skills::util::mkdir_p($dest);
            $r = skills::core::evidence_copy($src, $dest,
                { file_max => $FILE_MAX, total_max => $TOTAL_MAX, used => $used }, $index);
        }
        $used += $r->{bytes} // 0 if $r->{status} =~ /\A(copied|redacted)\z/;
        my %row = (status => $r->{status}, copy => $r->{copy}, origin => $origin_label // $src // $path, src => $src,
                   bytes => $r->{bytes}, sha256 => $r->{sha256}, mtime => $r->{mtime}, scan => $r->{scan},
                   rules => $r->{rules}, where => $where, ts => skills::util::iso_local($now));
        push @rows, \%row;
        skills::util::append_line("$dir/evidence.jsonl", skills::util::json_encode(\%row) . "\n");
    }

    for my $r (@rows) {
        skills::cli::say(join ' ', $r->{status}, ($r->{copy} // '-'), ($r->{bytes} // 0),
            (substr($r->{sha256} // '', 0, 8) || '-'), $r->{origin});
    }
    my $all = skills::stage::evidence_rows($dir);
    if (grep { $_->{where} eq 'keep' && $_->{copy} } @$all) {
        my ($n, $b) = _dir_size($keep_dir);
        skills::cli::say(sprintf('Evidence: %s/ (%d files, %.1f MB; MANIFEST.tsv)', $keep_dir, $n, $b / 1048576));
    }
    if (grep { $_->{where} eq 'dispose' && $_->{copy} } @$all) {
        my $kd = $ctx->{settings}{disposable_keep_days};
        my $note = (!defined $kd || $kd eq '' || $kd eq '0') ? 'kept until you remove it' : "retention $kd days";
        skills::cli::say("Disposable: $disp_dir/ ($note)");
    }
    my $stamp = skills::util::stamp($now);
    for my $r (@rows) {
        if ($r->{status} eq 'ref-only') {
            skills::cli::say(sprintf('Ref-only: %s — %d B, sha256 %s', $r->{origin}, $r->{bytes} // 0, substr($r->{sha256} // '', 0, 8)));
        } elsif ($r->{status} eq 'missing') {
            skills::cli::say("Volatile: $r->{origin} — missing at $stamp");
        } elsif ($r->{status} eq 'withheld') {
            my $rules = ref $r->{rules} eq 'ARRAY' && @{ $r->{rules} } ? ' (' . join(',', @{ $r->{rules} }) . ')' : '';
            skills::cli::say("Volatile: $r->{origin} — withheld by the secret gate$rules");
        }
    }
    my $quota = $ctx->{settings}{evidence_quota_mb};
    if (defined $quota && $quota =~ /\A\d+\z/ && $quota > 0) {
        my $tot = 0;
        for my $sub ('evidence', 'compact') { my (undef, $b) = _dir_size("$bucket/$sub"); $tot += $b }
        my $mb = $tot / 1048576;
        skills::cli::say(sprintf('WARN quota %s %d', $bucket, int($mb + 0.5))) if $mb > $quota;
    }
    return 0;
}

# git for a patch: up to one byte over the file cap is kept, so an over-cap patch is seen
# as such (never cut short and copied as if whole).
sub _git_bytes {
    my ($top, @args) = @_;
    return { rc => -1, out => '' } unless skills::gitfacts::usable();
    return skills::util::run(['git', '-C', $top, @args], 10000, trace => 'git', max_bytes => $FILE_MAX + 1);
}

sub _paths_z {
    my ($r) = @_;
    return undef unless $r->{rc} == 0;
    return [ map { skills::util::text($_) } grep { $_ ne '' } split /\0/, $r->{out} ];
}

# Scratch git clone with local commits -> one patch per commit plus the uncommitted diff
# (TPL §5 "scratch-clone patch series"), built in memory: nothing is written until the
# gate has run (RRP-01). Returns {name, label, top, bytes, paths}; a clone outside git
# gives one row with no bytes (missing).
sub _clone_patches {
    my ($clone) = @_;
    my $src = skills::util::abs_path($clone) // $clone;
    my $w = skills::gitfacts::where($src);
    return ({ name => undef, label => $src }) unless $w->{in_git};
    my $top = $w->{worktree};
    my @res;
    my $rl = skills::gitfacts::git($top, 'rev-list', '--reverse', "--max-count=$CLONE_MAX", 'HEAD', '--not', '--remotes');
    my @shas = $rl->{rc} == 0 ? grep { /\A[0-9a-f]{40}\z/ } split /\n/, $rl->{out} : ();
    my $i = 0;
    for my $sha (@shas) {
        $i++;
        my $fp = _git_bytes($top, 'format-patch', '--stdout', '-1', $sha);
        next if $fp->{rc} != 0 || $fp->{out} eq '';
        # every path the commit touches, both sides of a rename
        my $paths = _paths_z(_git_bytes($top, 'diff-tree', '--no-commit-id', '--name-only', '-r', '--root', '--no-renames', '-z', $sha));
        push @res, { name => sprintf('%04d-%s.patch', $i, substr($sha, 0, 8)), label => "$top#" . substr($sha, 0, 8),
                     top => $top, bytes => $fp->{out}, paths => $paths };
    }
    my $d = _git_bytes($top, 'diff', 'HEAD', '--binary');
    if ($d->{rc} == 0 && $d->{out} ne '') {
        my $paths = _paths_z(_git_bytes($top, 'diff', 'HEAD', '--name-only', '--no-renames', '-z'));
        push @res, { name => 'uncommitted.patch', label => "$top#uncommitted", top => $top, bytes => $d->{out}, paths => $paths };
    }
    return @res;
}

# One in-memory patch through the gate (RRP-01), the way a file is gated (handoff-spec §10):
# over the caps -> ref-only; a touched path that the name gate refuses (.netrc, *.sqlite,
# a transcript), or a path list git could not give -> withheld whole; a HARD hit in the
# text -> withheld; a WARN hit -> a redacted copy; else copied. Only the gated result is
# written, and only into the evidence folder.
sub _gate_patch {
    my ($pt, $dest, $used) = @_;
    my $bytes = $pt->{bytes};
    my $sha = skills::util::sha256_hex($bytes);
    my %r = (copy => undef, bytes => length $bytes, sha256 => $sha,
             mtime => skills::util::iso_local(skills::util::now()), rules => []);
    if (length($bytes) > $FILE_MAX || $used + length($bytes) > $TOTAL_MAX) {
        return { %r, status => 'ref-only', scan => 'ref-only' };
    }
    my $paths = $pt->{paths};
    if (!$paths || grep { skills::core::denied_path("$pt->{top}/$_") } @$paths) {
        return { %r, status => 'withheld', scan => 'withheld', rules => ['deny-name'] };
    }
    my $hits = skills::core::secrets_scan($bytes);
    my %u;
    my @ids = grep { !$u{$_}++ } map { $_->{rule} } @$hits;
    if (grep { $_->{class} eq 'HARD' } @$hits) {
        return { %r, status => 'withheld', scan => 'withheld', rules => \@ids };
    }
    my ($out, $status) = ($bytes, 'copied');
    if (@$hits) { ($out) = skills::core::secrets_redact($bytes); $status = 'redacted' }
    skills::util::mkdir_p($dest);
    my ($stem, $ext) = $pt->{name} =~ /\A(.*?)((?:\.[^.]+)?)\z/;
    my $p = skills::util::unique_path($dest, $stem, $ext);
    skills::util::write_excl($p, $out, 0600) or die "evidence: $p exists\n";
    return { %r, status => $status, copy => $p, scan => ($status eq 'copied' ? 'full' : 'redacted'), rules => \@ids };
}

# A directory argument stands for its regular files (at most 100, sorted).
sub _expand {
    my ($where, $path) = @_;
    my $abs = skills::util::abs_path($path) // $path;
    return ([ $where => $path ]) unless -d $abs;
    my (@files, @stack);
    @stack = ($abs);
    while (@stack && @files < 100) {
        my $x = shift @stack;
        for my $e (skills::util::list_dir($x)) {
            my $p = "$x/$e";
            next if -l $p;
            if (-d $p) { push @stack, $p unless $e eq '.git'; next }
            push @files, $p if -f $p;
            last if @files >= 100;
        }
    }
    return map { [ $where => $_ ] } @files;
}

sub _dir_size {
    my ($d) = @_;
    my ($n, $b) = (0, 0);
    return (0, 0) unless -d $d;
    my @stack = ($d);
    while (@stack) {
        my $x = pop @stack;
        for my $e (skills::util::list_dir($x)) {
            my $p = "$x/$e";
            if (-l $p) { next }
            if (-d $p) { push @stack, $p; next }
            next if $e eq 'MANIFEST.tsv';
            $n++;
            $b += -s $p // 0;
        }
    }
    return ($n, $b);
}

1;

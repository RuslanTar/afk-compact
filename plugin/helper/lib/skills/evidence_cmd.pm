package skills::evidence_cmd;
# lib/skills/evidence_cmd.pm: `evidence --stage DIR [--keep P…] [--dispose P…]
# [--clone DIR…]` (HDN §6, TPL §5). Needed-later copies go to
# <bucket>/evidence/<stem>/, disposable ones to today's
# <disposable_root>/<YYYY-MM-DD>/<stem>-evidence/. Caps, secret gate and
# cross-bucket dedupe are the core evidence.copy seam's.
use strict;
use warnings;
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
    for my $c (@clone) { push @jobs, map { [ keep => $_->[0], $_->[1] ] } _clone_patches($dir, $c) }

    my @rows;
    for my $j (@jobs) {
        my ($where, $path, $origin_label) = @$j;
        my $src = defined $path ? (skills::util::abs_path($path) // $path) : undef;
        my $dest = $where eq 'keep' ? $keep_dir : $disp_dir;
        my $r;
        if (!defined $src || !-e $src || -d _) {
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
    my $hhmm = skills::util::hhmm($now);
    for my $r (@rows) {
        if ($r->{status} eq 'ref-only') {
            skills::cli::say(sprintf('Ref-only: %s — %d B, sha256 %s', $r->{origin}, $r->{bytes} // 0, substr($r->{sha256} // '', 0, 8)));
        } elsif ($r->{status} eq 'missing') {
            skills::cli::say("Volatile: $r->{origin} — missing at $hhmm");
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

# Scratch git clone with local commits → patch files in the stage
# (TPL §5 "scratch-clone patch series"). Returns [path, origin label].
sub _clone_patches {
    my ($stage, $clone) = @_;
    my $src = skills::util::abs_path($clone) // $clone;
    my $w = skills::gitfacts::where($src);
    return ([ undef, $src ]) unless $w->{in_git};
    my $top = $w->{worktree};
    my $out = "$stage/clone-" . File::Basename::basename($top);
    my $n = 2;
    $out = "$stage/clone-" . File::Basename::basename($top) . '-' . $n++ while -e $out;
    skills::util::mkdir_p($out);
    my @res;
    my $rl = skills::gitfacts::git($top, 'rev-list', '--reverse', "--max-count=$CLONE_MAX", 'HEAD', '--not', '--remotes');
    my @shas = $rl->{rc} == 0 ? grep { /\A[0-9a-f]{40}\z/ } split /\n/, $rl->{out} : ();
    my $i = 0;
    for my $sha (@shas) {
        $i++;
        my $fp = skills::gitfacts::git($top, 'format-patch', '--stdout', '-1', $sha);
        next if $fp->{rc} != 0;
        my $p = sprintf('%s/%04d-%s.patch', $out, $i, substr($sha, 0, 8));
        skills::util::write_excl($p, $fp->{out}, 0600);
        push @res, [ $p, "$top#" . substr($sha, 0, 8) ];
    }
    my $d = skills::gitfacts::git($top, 'diff', 'HEAD', '--binary');
    if ($d->{rc} == 0 && $d->{out} ne '') {
        my $p = "$out/uncommitted.patch";
        skills::util::write_excl($p, $d->{out}, 0600);
        push @res, [ $p, "$top#uncommitted" ];
    }
    return @res;
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

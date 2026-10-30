package skills::restore;
# lib/skills/restore.pm: `verify <handoff>`, `restore-evidence <handoff>
# --to DIR` and `stash <path>` (resume R6, R7; RDN). Copies only, with
# private modes; nothing is moved or deleted.
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::store;

sub _handoff_arg {
    my ($argv, $usage) = @_;
    die skills::cli::usage($usage) unless @$argv == 1;
    my $p = skills::util::abs_path($argv->[0]);
    die skills::cli::refuse('not-found') unless defined $p && -f $p;
    return $p;
}

# verify: one row per MANIFEST entry, ok · missing · withheld · redacted. A copy recorded under an
# old default root (~/.claude/trash-staging, ~/.claude/handoffs) that is gone there is read under the
# new root, where `migrate --apply` put it (STATE-ROOT; skills::ctx::follow).
sub verify {
    my ($argv) = @_;
    skills::cli::opts($argv);
    my $p = _handoff_arg($argv, 'verify <handoff>');
    my $ctx = skills::ctx::new({});
    my $rows = skills::store::read_manifest(skills::store::manifest_path($p));
    if (!$rows) { skills::cli::say('no manifest'); return 0 }
    for my $r (@$rows) {
        my $scan = $r->{scan} // '';
        my $copy = skills::ctx::follow($ctx, $r->{copy_path} // '');
        if ($scan eq 'withheld') { skills::cli::say("withheld $r->{origin}"); next }
        if ($scan eq 'ref-only') {
            my $sz = -s $r->{origin};
            skills::cli::say((defined $sz && ($r->{bytes} eq '' || $sz == $r->{bytes}) ? 'ok' : 'missing') . " $r->{origin}");
            next;
        }
        if ($copy eq '' || !-f $copy) { skills::cli::say('missing ' . ($copy || $r->{origin})); next }
        if ($scan eq 'redacted') { skills::cli::say("redacted $copy"); next }
        my $sha = skills::util::sha256_file($copy) // '';
        skills::cli::say($sha eq ($r->{sha256} // '') ? "ok $copy" : "missing $copy sha-differs");
    }
    return 0;
}

# restore-evidence: copy the listed files into DIR (0700/0600), never move; a copy gone from an old
# default root is read under the new one, as in verify.
sub restore {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'to=s');
    my $p = _handoff_arg($argv, 'restore-evidence <handoff> --to DIR');
    my $ctx = skills::ctx::new({});
    die skills::cli::usage('--to DIR') unless defined $o->{to} && $o->{to} ne '';
    my $rows = skills::store::read_manifest(skills::store::manifest_path($p));
    die skills::cli::refuse('no-manifest') unless $rows;
    my $to = skills::util::abs_path($o->{to});
    skills::util::mkdir_p($to);
    for my $r (@$rows) {
        my $scan = $r->{scan} // '';
        next if $scan eq 'withheld' || $scan eq 'ref-only';
        my $src = skills::ctx::follow($ctx, $r->{copy_path} // '');
        next unless $src ne '' && -f $src;
        my $name = File::Basename::basename($src);
        my ($stem, $ext) = $name =~ /\A(.*?)((?:\.[^.]+)?)\z/;
        my $dest = skills::util::unique_path($to, $stem, $ext);
        my $res = skills::util::copy_file($src, $dest, 0600);
        skills::cli::say($dest) if $res eq 'copied';
    }
    return 0;
}

# stash: copy one file into today's disposable folder; print the copy path
# (the last line). The secret gate runs first (TPL §5): withhold → REFUSED:
# withheld; redact → a redacted copy, its rule ids (never values) printed as
# `ADVISORY secret-hard rules=<ids>` and, for WARN hits, `ADVISORY secret-warn
# rules=<ids>` (D-13); copy → a byte copy.
sub stash {
    my ($argv) = @_;
    skills::cli::opts($argv);
    die skills::cli::usage('stash <path>') unless @$argv == 1;
    my $src = skills::util::abs_path($argv->[0]);
    die skills::cli::refuse('not-found') unless defined $src && -f $src;
    my $ctx = skills::ctx::new({});
    my $rr = skills::core::roots_check($ctx->{settings});
    die skills::cli::refuse($rr) if $rr;
    # The gate's verdict and the bytes it scanned (RRP-06): those bytes are what is written,
    # never a second read of the file (bytes appended in between were never scanned; a file
    # larger than the gate's scan is withheld as too-large).
    my ($verdict, $hits, $raw) = skills::core::classify_file_hits($src);
    die skills::cli::refuse('withheld') if $verdict eq 'withhold';
    die "stash: the gate returned no scanned bytes for $src\n" unless defined $raw;
    my $now = skills::util::now();
    my $dir = "$ctx->{disposable}/" . skills::util::ymd($now) . '/stash';
    skills::util::mkdir_p($dir);
    my $name = File::Basename::basename($src);
    my ($stem, $ext) = $name =~ /\A(.*?)((?:\.[^.]+)?)\z/;
    my $dest = skills::util::unique_path($dir, skills::util::stem_time($now) . "_$stem", $ext);
    if ($verdict eq 'redact') {
        my ($red, $rh) = skills::core::secrets_redact($raw);
        skills::util::write_excl($dest, $red, 0600) or die "stash: exists\n";
        my %by;
        $by{ $_->{class} eq 'HARD' ? 'hard' : 'warn' }{ $_->{rule} } = 1 for @$hits, @$rh;
        for my $c (qw(hard warn)) {
            skills::cli::say("ADVISORY secret-$c rules=" . join(',', sort keys %{ $by{$c} })) if $by{$c};
        }
    } else {
        skills::util::write_excl($dest, $raw, 0600) or die "stash: exists\n";
    }
    skills::cli::say($dest);
    return 0;
}

1;

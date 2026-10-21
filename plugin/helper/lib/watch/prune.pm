package watch::prune;
# lib/watch/prune.pm: `watch prune --days N` (OWNER-DECISIONS D-9; BUILD-PLAN
# §3.1). Owner: WP-watch. Built and tested, NOT wired into any hook until the
# owner answers E-8: it is the plugin's only deletion code.
#
# It deletes only per-session files under <watch> whose session id is a UUID:
# `<sid>.jsonl`, `<sid>.classic.jsonl`, `<sid>.alerts.jsonl` and the `<sid>/`
# tree, and only when every one of them is older than the cut (a session with
# any newer file is kept whole). Global files (heal/, fingerprints/,
# version.json, evidence-index.tsv, anything else) are never touched. A
# symlink or a non-regular file anywhere in a session's set keeps the set.
use strict;
use warnings;

my $UUID = qr/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/;

# Walk one path with lstat; returns (ok, newest mtime, [files], [dirs], bytes).
sub _walk {
    my ($path) = @_;
    my @st = lstat $path or return (0);
    return (0) if -l _;
    if (-f _) { return (1, $st[9], [$path], [], $st[7]) }
    return (0) unless -d _;
    my ($newest, @files, @dirs, $bytes) = ($st[9]);
    $bytes = 0;
    opendir(my $dh, $path) or return (0);
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $e (@e) {
        my ($ok, $mt, $f, $d, $b) = _walk("$path/$e");
        return (0) unless $ok;
        $newest = $mt if $mt > $newest;
        push @files, @$f;
        push @dirs, @$d;
        $bytes += $b;
    }
    push @dirs, $path;
    return (1, $newest, \@files, \@dirs, $bytes);
}

sub prune {
    my (%a) = @_;
    my $watch = $a{watch};
    my $cut = $a{now} - $a{days} * 86400;
    my %res = (files => 0, bytes => 0, sessions => 0, kept => 0);
    my @st = lstat $watch;
    return \%res unless @st && -d _ && !-l _;
    opendir(my $dh, $watch) or return \%res;
    my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    my %by;
    for my $n (@names) {
        if ($n =~ /\A($UUID)(?:\.jsonl|\.classic\.jsonl|\.alerts\.jsonl)?\z/) {
            push @{ $by{ lc $1 } }, $n;
        }
    }
    for my $sid (sort keys %by) {
        my ($ok, $newest, @files, @dirs) = (1, 0);
        my $bytes = 0;
        for my $n (@{ $by{$sid} }) {
            my ($k, $mt, $f, $d, $b) = _walk("$watch/$n");
            unless ($k) { $ok = 0; last }
            $newest = $mt if $mt > $newest;
            push @files, @$f;
            push @dirs, @$d;
            $bytes += $b;
        }
        if (!$ok || $newest >= $cut) { $res{kept}++; next }
        my $removed = 0;
        for my $f (@files) {
            next unless index($f, "$watch/") == 0;
            if (unlink $f) { $removed++; $res{files}++ }
        }
        for my $d (@dirs) {
            next unless index($d, "$watch/") == 0;
            rmdir $d;
        }
        $res{bytes} += $bytes;
        $res{sessions}++ if $removed;
    }
    return \%res;
}

1;

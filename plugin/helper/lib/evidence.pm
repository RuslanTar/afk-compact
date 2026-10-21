package evidence;
# lib/evidence.pm: one automatic evidence copy (MOD-SPEC §10; S-6, S-9, S-10).
# Owner: WP-core. Caps 10 MB per file and 50 MB per compaction (bigger -> ref-only
# with bytes, sha256, mtime and <= 40 head/tail lines of text, redacted); dedupe by
# sha256 across buckets through <watch>/evidence-index.tsv (O_APPEND rows); the
# secret gate decides copy / redacted copy / withheld; tasks/*.output -> a redacted
# head/tail excerpt of <= 80 lines. Directories 0700, files 0600.
use strict;
use warnings;

our $FILE_MAX = 10 * 1024 * 1024;
our $TOTAL_MAX = 50 * 1024 * 1024;

sub _index_lookup {
    my ($index, $sha) = @_;
    open(my $fh, '<:raw', $index) or return undef;
    my $hit;
    while (my $l = <$fh>) {
        next unless index($l, $sha) == 0;
        my @f = split /\t/, $l;
        if ($f[0] eq $sha && defined $f[1] && -e $f[1]) { $hit = $f[1]; last }
    }
    close $fh;
    return $hit;
}

sub _is_text {
    my ($bytes) = @_;
    return 0 if index($bytes, "\0") >= 0;
    return 1;
}

sub _excerpt {
    my ($raw, $n) = @_;
    my @l = split /\n/, $raw, -1;
    pop @l if @l && $l[-1] eq '';
    return ($raw, scalar @l) if @l <= 2 * $n;
    my $skipped = @l - 2 * $n;
    return (join("\n", @l[0 .. $n - 1], "[… $skipped lines not copied …]", @l[$#l - $n + 1 .. $#l]) . "\n", 2 * $n);
}

sub _unique {
    my ($dir, $name) = @_;
    $name =~ s/[^A-Za-z0-9._-]/_/g;
    $name = 'file' if $name eq '' || $name =~ /^\.+$/;
    my $p = "$dir/$name";
    my $i = 2;
    while (-e $p) { $p = "$dir/$i-$name"; $i++ }
    return $p;
}

sub _manifest {
    my ($dir, %r) = @_;
    my $line = join("\t", map { my $v = $_ // '-'; $v =~ s/[\t\n]/ /g; $v }
        $r{copy}, $r{origin}, $r{bytes}, $r{sha256}, $r{mtime}, util::iso(util::now()), $r{mode}, $r{scan}, $r{regen}, $r{meaning}) . "\n";
    my $m = "$dir/MANIFEST.tsv";
    util::append($m, "copy_path\torigin\tbytes\tsha256\tmtime\tcopied_at\tmode\tscan\tregen_cmd\tmeaning\n") unless -e $m;
    util::append($m, $line);
}

# copy(src, dest_dir, caps, index) -> row {status, origin, copy, bytes, sha256, sha8, mtime, scan, rules}
#   caps: {used => \$bytes_so_far, file_max, total_max, manifest => 1, ref_file => 1}
sub copy {
    my ($src, $dest_dir, $caps, $index) = @_;
    $caps ||= {};
    my $used = $caps->{used} || \(my $u = 0);
    my $fmax = $caps->{file_max} // $FILE_MAX;
    my $tmax = $caps->{total_max} // $TOTAL_MAX;
    # caps.manifest => 0: no MANIFEST.tsv rows in dest_dir (the handoff skill writes its own at
    # publish); caps.ref_file => 0: an over-cap file stays a ref-only row with no excerpt file.
    my $mf = !(exists $caps->{manifest} && !$caps->{manifest});
    my $rf = !(exists $caps->{ref_file} && !$caps->{ref_file});
    my %row = (origin => $src, copy => undef, bytes => undef, sha256 => undef, sha8 => undef, mtime => undef, rules => []);
    if (!-e $src || !-f _) { return { %row, status => 'missing' } }
    my @st = stat $src;
    @row{qw(bytes mtime)} = ($st[7], util::iso($st[9]));
    if (secrets::denied_name($src) || secrets::never_copy($src)) {
        _manifest($dest_dir, %row, copy => '-', scan => 'withheld', mode => '-', meaning => 'withheld by name') if $mf;
        return { %row, status => 'withheld', rules => ['deny-name'] };
    }
    my $sha = sha::hex256_file($src);
    @row{qw(sha256 sha8)} = ($sha, defined $sha ? substr($sha, 0, 8) : undef);
    if (defined $sha && defined $index && (my $prev = _index_lookup($index, $sha))) {
        return { %row, status => 'dup', copy => $prev };
    }
    util::mkdir_p($dest_dir);
    my $base = util::basename($src);
    my $is_task = $src =~ m{/tasks/[^/]+\.output$} ? 1 : 0;
    if (!$is_task && ($row{bytes} > $fmax || $$used + $row{bytes} > $tmax)) {
        return { %row, status => 'ref-only' } unless $rf;
        my $head = util::read_file($src, 64 * 1024) // '';
        my $txt = "origin: $src\nbytes: $row{bytes}\nsha256: " . ($sha // 'unavailable') . "\nmtime: $row{mtime}\n";
        if (_is_text($head)) {
            my $tail = util::read_tail($src, 64 * 1024) // '';
            my @h = (split /\n/, $head)[0 .. 39];
            my @t = (split /\n/, $tail);
            @t = @t[($#t > 39 ? $#t - 39 : 0) .. $#t];
            my $ex = join("\n", (grep { defined } @h), '[…]', @t) . "\n";
            ($ex) = secrets::redact($ex);
            $txt .= "--- head/tail (redacted) ---\n$ex";
        }
        my $ref = _unique($dest_dir, "$base.ref.txt");
        util::write_excl($ref, $txt, 0600);
        _manifest($dest_dir, %row, copy => $ref, scan => 'ref-only', mode => '0600', meaning => 'over the size cap') if $mf;
        return { %row, status => 'ref-only', copy => $ref };
    }
    my ($class, $hits) = $is_task ? ('excerpt', []) : secrets::classify_file($src);
    my @rules = map { $_->{rule} } @$hits;
    if ($class eq 'withhold') {
        _manifest($dest_dir, %row, copy => '-', scan => 'withheld', mode => '-', meaning => 'secret gate') if $mf;
        return { %row, status => 'withheld', rules => \@rules };
    }
    my $dst = _unique($dest_dir, $base);
    if ($class eq 'excerpt' || $class eq 'redact') {
        my $raw = util::read_file($src, 12 * 1024 * 1024) // '';
        my $scan = 'redacted';
        if ($class eq 'excerpt') { ($raw) = _excerpt($raw, 40); $scan = 'excerpt' }
        my ($red, $rh) = secrets::redact($raw);
        push @rules, map { $_->{rule} } @$rh;
        my %u; @rules = grep { !$u{$_}++ } @rules;
        util::write_excl($dst, $red, 0600);
        $$used += length $red;
        util::append($index, join("\t", $sha // '-', $dst, $src, $row{bytes}, util::iso(util::now())) . "\n") if defined $index && defined $sha;
        _manifest($dest_dir, %row, copy => $dst, scan => $scan, mode => '0600', meaning => 'automatic evidence copy') if $mf;
        return { %row, status => 'redacted', copy => $dst, rules => \@rules, scan => $scan };
    }
    util::copy_file($src, $dst, excl => 1, mode => 0600);
    $$used += $row{bytes};
    util::append($index, join("\t", $sha // '-', $dst, $src, $row{bytes}, util::iso(util::now())) . "\n") if defined $index && defined $sha;
    _manifest($dest_dir, %row, copy => $dst, scan => 'full', mode => '0600', meaning => 'automatic evidence copy') if $mf;
    return { %row, status => 'copied', copy => $dst };
}

# du(dir) -> bytes, own tree walk (File::Find is off the floor)
sub du {
    my ($dir) = @_;
    my $n = 0;
    my @stack = ($dir);
    while (@stack) {
        my $d = pop @stack;
        for my $e (util::list_dir($d)) {
            my $p = "$d/$e";
            if (-l $p) { next }
            elsif (-d _) { push @stack, $p }
            elsif (-f _) { $n += -s _ }
        }
    }
    return $n;
}

1;

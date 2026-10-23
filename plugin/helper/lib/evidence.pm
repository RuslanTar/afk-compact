package evidence;
# lib/evidence.pm: one automatic evidence copy (MOD-SPEC §10; S-6, S-9, S-10).
# Owner: WP-core. Caps 10 MB per file and 50 MB per compaction (bigger -> ref-only
# with bytes, sha256, mtime and <= 40 head/tail lines of text, redacted); dedupe by
# sha256 across buckets through <watch>/evidence-index.tsv (O_APPEND rows); the
# secret gate decides copy / redacted copy / withheld; agent output in tasks/*.output is
# always withheld (BD-4); a shell or monitor job's tasks/*.output -> a redacted
# head/tail excerpt of <= 80 lines. Directories 0700, files 0600.
use strict;
use warnings;
use utf8;

our $FILE_MAX = 10 * 1024 * 1024;
our $TOTAL_MAX = 50 * 1024 * 1024;    # the evidence_total_max_mb fallback (SK-5)
# SK-5 (owner xxxxxxxx-14, S-SETTINGS E5): the total from evidence_total_max_mb, clamped 10-500 MB.
sub total_max { my ($mb) = eval { settings::num_clamped("evidence_total_max_mb") }; return defined $mb ? $mb * 1024 * 1024 : $TOTAL_MAX }

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
    # text from here on (§2.6): each line decoded once, a line that is not UTF-8 reads as Latin-1
    my @l = map { util::text($_) } split /\n/, $raw, -1;
    pop @l if @l && $l[-1] eq '';
    return ($raw, scalar @l) if @l <= 2 * $n;
    # n head lines + the marker line + n-1 tail lines: the excerpt is at most 2n lines (AT-E-05)
    my $skipped = @l - (2 * $n - 1);
    return (join("\n", @l[0 .. $n - 1], "[… $skipped lines not copied …]", @l[$#l - $n + 2 .. $#l]) . "\n", 2 * $n);
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
    my $tmax = $caps->{total_max} // total_max();
    # caps.manifest => 0: no MANIFEST.tsv rows in dest_dir (the handoff skill writes its own at
    # publish); caps.ref_file => 0: an over-cap file stays a ref-only row with no excerpt file.
    my $mf = !(exists $caps->{manifest} && !$caps->{manifest});
    my $rf = !(exists $caps->{ref_file} && !$caps->{ref_file});
    my %row = (origin => $src, copy => undef, bytes => undef, sha256 => undef, sha8 => undef, mtime => undef, rules => []);
    if (!-e $src || !-f _) { return { %row, status => 'missing' } }
    my @st = stat $src;
    @row{qw(bytes mtime)} = ($st[7], util::iso($st[9]));
    # BD-4 (C-STORE D6, MOD-SPEC §10): agent output is always withheld, whatever form the
    # tasks/<id>.output takes; only a shell or monitor job's own output gets the excerpt
    if ($src =~ m{/tasks/[^/]+\.output\z} && (my $det = agent_output($src))) {
        _manifest($dest_dir, %row, copy => '-', scan => 'withheld', mode => '-', meaning => 'agent output') if $mf;
        return { %row, status => 'withheld', rules => ['agent-output'], detector => $det };
    }
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
            my @h = map { util::text($_) } (split /\n/, $head)[0 .. 39];
            my @t = map { util::text($_) } (split /\n/, $tail);
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
    my ($class, $hits, $scanned) = $is_task ? ('excerpt', []) : secrets::classify_file($src);
    my @rules = map { $_->{rule} } @$hits;
    if ($class eq 'withhold') {
        _manifest($dest_dir, %row, copy => '-', scan => 'withheld', mode => '-', meaning => 'secret gate') if $mf;
        return { %row, status => 'withheld', rules => \@rules };
    }
    my $dst = _unique($dest_dir, $base);
    if ($class eq 'excerpt' || $class eq 'redact') {
        # a redact copy writes the bytes the gate scanned (classify_file reads the file once)
        my $raw = $class eq 'redact' && defined $scanned ? $scanned : util::read_file($src, 12 * 1024 * 1024) // '';
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

# agent_output(path of a tasks/<id>.output) -> the BD-4 detector that fires (a, b, c) or undef:
# (a) its real path is a transcript or session JSONL (the never-copy gate, PRIV-02); (b) this
# session's sidecar or job record lists task <id> with a type other than shell or monitor;
# (c) its first non-empty line parses as a transcript row (a JSON object with type and
# sessionId or parentUuid). Read in memory only.
our %SHELL_TYPES = map { $_ => 1 } qw(shell monitor);
# the longest first line detector (c) reads whole (the excerpt read cap)
our $FIRST_LINE_MAX = 12 * 1024 * 1024;
sub agent_output {
    my ($src) = @_;
    my $real = eval { util::real_path($src) };
    return 'a' if defined $real && $real ne $src && ($real =~ /\.jsonl\z/i || secrets::never_copy($real));
    my ($id) = util::basename($src) =~ /\A(.+)\.output\z/;
    my $sd = rc::sid_dir();
    if (defined $id && defined $sd) {
        my $slot = eval { sidecar::newest($sd) };
        my ($t) = grep { ref $_ eq 'HASH' && ($_->{id} // '') eq $id } @{ ref $slot eq 'HASH' && ref $slot->{tasks} eq 'ARRAY' ? $slot->{tasks} : [] };
        my $type = $t ? $t->{type} : undef;
        if (!defined $type) { my $j = eval { jobrec::record_of($sd, $id) }; $type = $j->{type} if ref $j eq 'HASH' }
        return 'b' if defined $type && !$SHELL_TYPES{$type};
    }
    my ($l, $cut) = _first_line($src, $FIRST_LINE_MAX);
    return undef unless defined $l && $l =~ /^\s*\{/;
    # fail closed: a JSON-looking first line longer than the cap cannot be parsed, so it is
    # treated as a transcript row (withheld) rather than excerpted
    return 'c' if $cut;
    my $j = eval { jsonc::decode($l) };
    return 'c' if ref $j eq 'HASH' && defined $j->{type} && (exists $j->{sessionId} || exists $j->{parentUuid});
    return undef;
}

# _first_line(path, cap) -> (the first non-empty line without its newline, cut flag), read in
# 64 KB blocks up to cap bytes, so a long first row (a long agent prompt) is read whole; cut is
# 1 when the line runs past the cap. Blank lines before it are skipped. (undef, 0) when unreadable
# or when no non-empty line starts within the cap.
sub _first_line {
    my ($src, $cap) = @_;
    open(my $fh, '<:raw', $src) or return (undef, 0);
    my ($buf, $total, $from) = ('', 0, 0);
    while (1) {
        $from = 0 if $buf =~ s/\A(?:[^\S\n]*\n)+//;
        my $nl = index($buf, "\n", $from);    # scan only the bytes not searched yet
        if ($nl >= 0) { close $fh; return (substr($buf, 0, $nl), 0) }
        $from = length $buf;
        if ($total >= $cap) { close $fh; return ($buf =~ /\S/ ? ($buf, 1) : (undef, 0)) }
        my $n = read($fh, my $chunk, 64 * 1024);
        last unless $n;
        $total += $n;
        $buf .= $chunk;
    }
    close $fh;
    return ($buf =~ /\S/ ? ($buf, 0) : (undef, 0));
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

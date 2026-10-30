package skills::store;
# lib/skills/store.pm: reading the handoff tree (TPL §3, §6; CONSISTENCY
# "Locations"): buckets, handoffs and copies, frontmatter, integrity.
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::core;
use skills::ctx;

# Frontmatter: `---` first line, `key: value` lines, closing `---`.
# Returns {ok, fm => {...}, body => text, body_line => n (1-based file line)}.
sub parse {
    my ($text) = @_;
    my %r = (ok => 0, fm => {}, body => $text, body_line => 1, has_fm => 0);
    return \%r unless defined $text;
    my @l = split /\n/, $text, -1;
    if (@l && $l[0] =~ /\A---\s*\z/) {
        $r{has_fm} = 1;
        for my $i (1 .. $#l) {
            if ($l[$i] =~ /\A---\s*\z/) {
                $r{ok} = 1;
                $r{body} = join("\n", @l[$i + 1 .. $#l]);
                $r{body_line} = $i + 2;
                last;
            }
            next if $l[$i] =~ /\A\s*(#|\z)/;
            if ($l[$i] =~ /\A([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*\z/) {
                my ($k, $v) = ($1, $2);
                $v =~ s/\A"(.*)"\z/$1/ or $v =~ s/\A'(.*)'\z/$1/;
                $r{fm}{$k} = $v;
            } else {
                $r{bad_line} //= $i + 1;
            }
        }
        $r{ok} = 0 if $r{bad_line};
    }
    return \%r;
}

sub read_doc {
    my ($path) = @_;
    my $t = skills::util::read_text($path, 1024 * 1024);
    return undef unless defined $t;
    my $d = parse($t);
    $d->{path} = $path;
    $d->{text} = $t;
    $d->{epoch} = skills::util::iso_to_epoch($d->{fm}{date});
    return $d;
}

# Integrity of one document (resume R1): ok | possibly truncated | legacy |
# unshaped | s=sub, plus marker facts.
# alias => 1 (owner 2026-10-23 xxxxxxxx-26, "Read-only alias"): the caller has shown the file is
# in the private store, not an export or an imported copy, and this session's or a lineage
# predecessor's (own chain); the one exception is skills::session_cmds::link_resume, which reads
# an ended candidate predecessor's handoff in the private store this way before it links that
# session into the chain (owner xxxxxxxx-26: resume tomorrow from a handoff written under the old
# name). Then a `kind: handoff` file with no marker under the current name
# whose marker and sentinel under a former name (settings.pm @FORMER_NAMES) share one nonce reads
# as that marker (`former` names it). Without the flag, or with any other mix, such a file stays
# what the current grammar says (legacy). Files are only read this way, never written.
sub integrity {
    my ($d, %o) = @_;
    my $det = skills::core::detect_summary($d->{body});
    my $fm = $d->{fm};
    my $writer = $fm->{writer} // '';
    my ($marker, $sentinel, $scope, $nonce, $former) = (0, 0, undef, undef, undef);
    if ($det) {
        $marker = defined $det->{marker_line} && $det->{marker_line} ne '-' ? 1 : 0;
        $sentinel = defined $det->{sentinel_from_end} && $det->{sentinel_from_end} ne '-' ? 1 : 0;
        $scope = $det->{scope};
        $nonce = $det->{nonce};
    }
    if ($o{alias} && !$marker && !$sentinel && ($fm->{kind} // '') eq 'handoff' && $writer !~ /\A(?:mod|postcompact-fallback)\z/) {
        my $f = skills::core::detect_former($d->{body});
        if ($f && (!defined $fm->{nonce} || $fm->{nonce} eq $f->{nonce})) {
            ($marker, $sentinel, $scope, $nonce, $former) = (1, 1, $f->{scope}, $f->{nonce}, $f->{name});
        }
    }
    my $res;
    if ($scope && $scope eq 'sub') {
        $res = 's=sub';
    } elsif ($writer eq 'mod' || $writer eq 'postcompact-fallback') {
        my $v = $fm->{verdict} // ($det ? $det->{verdict} : '') // '';
        $res = ($v eq 'ok' || $v eq 'ok-trailer') ? 'ok' : 'unshaped';
    } elsif (!$marker && !defined $fm->{kind}) {
        $res = 'legacy';
    } elsif ($marker && !$sentinel) {
        $res = 'possibly truncated';
    } elsif ($marker && $sentinel && $d->{ok} && (!defined $fm->{nonce} || !defined $nonce || $fm->{nonce} eq $nonce)) {
        $res = 'ok';
    } elsif (!$marker) {
        $res = 'legacy';
    } else {
        $res = 'possibly truncated';
    }
    return { integrity => $res, marker => $marker, sentinel => $sentinel, scope => $scope, nonce => $nonce,
             verdict => ($det ? $det->{verdict} : undef), former => $former };
}

# Bucket directories under <root>/<repo>/ (dot names skipped).
sub buckets {
    my ($root, $repo) = @_;
    my $base = "$root/$repo";
    return [ map { "$base/$_" } grep { !/\A\./ && -d "$base/$_" } skills::util::list_dir($base) ];
}

sub repos {
    my ($root) = @_;
    return [ grep { !/\A\./ && -d "$root/$_" } skills::util::list_dir($root) ];
}

# STATE-ROOT: the bucket folders of a repo in every read root (skills::ctx::read_roots: the store root,
# then the legacy root ~/.claude/handoffs while handoff_root is the default). Readers pool the
# documents of both and order them by frontmatter date; nothing is written under the legacy root.
sub read_buckets {
    my ($ctx, $repo) = @_;
    return [ map { @{ buckets($_, $repo) } } skills::ctx::read_roots($ctx) ];
}

# [[root, repo] …]: the repo folders of every read root.
sub read_repos {
    my ($ctx) = @_;
    return [ map { my $r = $_; map { [ $r, $_ ] } @{ repos($r) } } skills::ctx::read_roots($ctx) ];
}

# twin_buckets(ctx, bucket) -> the folders with the same <repo>/<bucket> name in every read root
# that has one (the given folder first); a folder under no read root is returned alone.
sub twin_buckets {
    my ($ctx, $bucket) = @_;
    my @roots = skills::ctx::read_roots($ctx);
    # a pin's bucket under an old default root that is gone: its copy under the new root (skills::ctx::follow)
    $bucket = skills::ctx::follow($ctx, $bucket);
    my $b = skills::util::abs_path($bucket) // $bucket;
    for my $r (@roots) {
        my $ar = skills::util::abs_path($r) // $r;
        next unless index($b, "$ar/") == 0;
        my $rel = substr($b, length($ar) + 1);
        return [ $bucket, grep { -d $_ && (skills::util::abs_path($_) // $_) ne $b } map { "$_/$rel" } @roots ];
    }
    return [$bucket];
}

# bucket_key(ctx, bucket) -> the folder's path below the read root that holds it (<repo>/<bucket>),
# so the same bucket in both read roots gives one key; a folder under no read root gives its own path.
sub bucket_key {
    my ($ctx, $bucket) = @_;
    my $b = skills::util::abs_path($bucket) // $bucket;
    for my $r (skills::ctx::read_roots($ctx)) {
        my $ar = skills::util::abs_path($r) // $r;
        $ar =~ s{/+\z}{};
        return substr($b, length($ar) + 1) if index($b, "$ar/") == 0;
    }
    return $b;
}

# in_store(ctx, path) -> 1 when the file's real path lies under a read root (the store root, or
# the legacy root, which counts as the own store, STATE-ROOT), component by component.
sub in_store {
    my ($ctx, $path) = @_;
    return 0 unless defined $path && $ctx;
    my $p = skills::util::abs_path($path);
    return 0 unless defined $p;
    for my $root (skills::ctx::read_roots($ctx)) {
        my $r = skills::util::abs_path($root);
        next unless defined $r;
        $r =~ s{/+\z}{};
        return 1 if index($p, "$r/") == 0;
    }
    return 0;
}

# Documents in a bucket: top-level handoffs, plus compact/ copies on request.
sub docs_in {
    my ($bucket, %o) = @_;
    my @paths = map { "$bucket/$_" } grep { /\.md\z/ && -f "$bucket/$_" } skills::util::list_dir($bucket);
    if ($o{compact}) {
        for my $sub ('compact', 'compact/subagents', 'compact/unattributed') {
            push @paths, map { "$bucket/$sub/$_" } grep { /\.md\z/ && -f "$bucket/$sub/$_" } skills::util::list_dir("$bucket/$sub");
        }
    }
    my @docs;
    for my $p (@paths) {
        my $d = read_doc($p) or next;
        $d->{bucket} = $bucket;
        $d->{is_copy} = ($p =~ m{/compact/}) ? 1 : 0;
        push @docs, $d;
    }
    return [ sort { ($b->{epoch} // 0) <=> ($a->{epoch} // 0) } @docs ];
}

sub is_handoff { my ($d) = @_; return (($d->{fm}{kind} // '') eq 'handoff') ? 1 : 0 }

# A private copy of a repository export (`project copy --from repo`, D-12 §1.5.9): never the
# carry base (DP-6), and its recipes are not local.
sub imported { my ($d) = @_; return (defined $d->{fm}{imported_from} && $d->{fm}{imported_from} ne '') ? 1 : 0 }

# A repository export (D-12 §1.5.5): `export: repo` in its frontmatter.
sub is_export { my ($d) = @_; return (($d->{fm}{export} // '') eq 'repo') ? 1 : 0 }

# Topic folders under a repository's export root <toplevel>/<decl.root> (D-12 §1.5.7),
# read-only: no symlinks followed, dot names skipped.
sub export_buckets {
    my ($top, $root) = @_;
    return [] unless defined $top && defined $root;
    my $base = "$top/$root";
    return [] unless -d $base && !-l $base;
    return [ map { "$base/$_" } grep { !/\A\./ && !-l "$base/$_" && -d "$base/$_" } skills::util::list_dir($base) ];
}

# Export documents of a repository root, each tagged {source => repo:<label>, export_root}.
sub export_docs {
    my ($top, $root, $label) = @_;
    my @out;
    for my $b (@{ export_buckets($top, $root) }) {
        for my $d (@{ docs_in($b) }) {
            next unless is_handoff($d) && is_export($d) && !-l $d->{path};
            $d->{source} = "repo:$label";
            $d->{export_root} = "$top/$root";
            push @out, $d;
        }
    }
    return \@out;
}

# Dedupe by (nonce, session_id): a private twin wins over its export, and the export path
# is kept on the twin as {export_path} (D-12 §1.5.7). Returns the exports with no twin.
sub dedupe_exports {
    my ($private, $exports) = @_;
    my %twin;
    for my $d (@$private) {
        my $k = join "\t", $d->{fm}{nonce} // '', $d->{fm}{session_id} // '';
        $twin{$k} //= $d if $d->{fm}{nonce} && $d->{fm}{session_id};
    }
    my @rest;
    for my $x (@$exports) {
        my $k = join "\t", $x->{fm}{nonce} // '', $x->{fm}{session_id} // '';
        if (my $t = $twin{$k}) { $t->{export_path} //= $x->{path}; next }
        push @rest, $x;
    }
    return \@rest;
}

# Refused or unpublished drafts in <bucket>/.staging/ (D-15).
sub drafts_in {
    my ($bucket) = @_;
    my $dir = "$bucket/.staging";
    my @out;
    for my $e (skills::util::list_dir($dir)) {
        my $st = "$dir/$e";
        next unless -d $st && -f "$st/body.md" && !-e "$st/published";
        my $set = eval { skills::util::json_decode(skills::util::read_file("$st/settings.json", 65536)) } || {};
        push @out, { path => "$st/body.md", stage => $st, date => $set->{date}, sid => $set->{session_id},
                     epoch => skills::util::iso_to_epoch($set->{date}) // ((stat "$st/body.md")[9]) };
    }
    return [ sort { $b->{epoch} <=> $a->{epoch} } @out ];
}

sub title_of {
    my ($d) = @_;
    for my $l (split /\n/, $d->{body}, 40) {
        return $1 if $l =~ /\A#\s+(.+?)\s*\z/;
    }
    return '';
}

# Line number (1-based, in the file) of a heading, or undef.
sub heading_line {
    my ($text, $literal) = @_;
    my $n = 0;
    for my $l (split /\n/, $text) {
        $n++;
        return $n if index($l, $literal) == 0;
    }
    return undef;
}

# The bucket directory a document sits in.
sub bucket_of {
    my ($path) = @_;
    my $d = File::Basename::dirname($path);
    $d = File::Basename::dirname($d) while $d =~ m{/(compact|subagents|unattributed)\z};
    return $d;
}

sub stem_of { my ($path) = @_; my $b = File::Basename::basename($path); $b =~ s/\.md\z//; return $b }

sub manifest_path {
    my ($path) = @_;
    return bucket_of($path) . '/evidence/' . stem_of($path) . '/MANIFEST.tsv';
}

my @MANIFEST_COLS = qw(copy_path origin bytes sha256 mtime copied_at mode scan regen_cmd meaning);
sub manifest_cols { return @MANIFEST_COLS }

sub read_manifest {
    my ($mpath) = @_;
    my $t = skills::util::read_text($mpath);
    return undef unless defined $t;
    my @rows;
    for my $l (split /\n/, $t) {
        next if $l eq '' || $l =~ /\Acopy_path\t/;
        my @f = split /\t/, $l, -1;
        my %r;
        @r{@MANIFEST_COLS} = map { defined $_ && $_ eq '-' ? '' : $_ } @f;
        push @rows, \%r;
    }
    return \@rows;
}

sub manifest_line {
    my ($r) = @_;
    return join("\t", map { my $v = $r->{$_}; (defined $v && $v ne '') ? ($v =~ s/[\t\n]/ /gr) : '-' } @MANIFEST_COLS) . "\n";
}

1;

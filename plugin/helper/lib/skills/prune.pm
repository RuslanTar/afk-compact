package skills::prune;
# lib/skills/prune.pm: `prune [--days N] [--min-mb N] [--root DIR]… [--all] [--apply --plan H]` (0.1.6
# PRUNE, owner 2026-11-08: a handoff folder should not hold a lot of data, and whoever cleans up
# weeks later must know what is safe to delete, so the small handoff files survive). User-run, and
# the prune skill's dry run then apply after the user's yes.
#   - Units: each <handoff_root>/<repo>/<bucket>/evidence/<stem>/ and each folder of a dated
#     <disposable_root>/<YYYY-MM-DD>/ (a handoff's disposable items, a compaction's sweep, stash/),
#     with the bucket and the handoff or summary copy each belongs to (its stem; `<stem>-evidence`;
#     a sweep named at checkpoint time, `<stamp>_<sid8>-<id6>-evidence`, the main copy with that
#     sid8 and id6, else the unattributed one). The 40 largest per root are listed, the rest
#     counted (--all lists every one).
#   - Age: the owning handoff's or copy's date (frontmatter, else mtime), else the newest file in
#     the folder. A folder is listed when it is older than --days (default disposable_keep_days, or
#     14 when that is 0), at least --min-mb large, and holds a file to delete.
#   - Never deleted: a handoff .md or a summary copy (none sits in a unit; a .md in one with
#     `kind: handoff` or `kind: compact-summary` is kept too), MANIFEST.tsv, a handoff's ledger.md
#     and inflight.md (its own text), links and special files, a file a handoff (or summary copy)
#     newer than the age cites (a MANIFEST.tsv row, or its path or a folder above it named in the
#     text, with or without a line reference `:120`, `:120-130` or `#L12`, in backticks, double or
#     single quotes with spaces, `~/`, `$HOME/`; `evidence/…` and `./evidence/…` read against that
#     handoff's bucket), and a file the evidence.jsonl of an unpublished draft newer than the age
#     names (a draft's age: its begin date or the newest mtime in its folder, whichever is later).
#     A young handoff's own folder (its restart recipes) is never old enough.
#   - --apply first marks every MANIFEST.tsv row (handoff and sweep manifests) whose copy it deletes
#     `pruned` (scan column), so verify reports `pruned`, not `missing`; then it unlinks the files
#     and removes the folders left empty (rmdir only). A file it could not delete gets its row back.
#     --apply needs the dry run's --plan (path, size and mtime of each file): a plan that differs
#     is refused and nothing is deleted; a file changed since is not deleted.
#   - Cache state (0.1.7): the files under ${XDG_STATE_HOME:-~/.local/state}/<plugin>/cache/ of
#     sessions that ended, or with no end were not written, more than 7 days ago (lib/cachestate.pm
#     stale), whatever --days says,
#     go with the rest (in the plan and the total).
#   - Read-only folders: the old default ~/.claude/handoffs and ~/.claude/trash-staging (while the
#     setting is the default) and every --root folder are listed, never written.
use strict;
use warnings;
use utf8;
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::store;

our $DEFAULT_DAYS = 14;
our $LIST_MAX = 40;
our $TEXT_MAX = 2 * 1024 * 1024;
my $DAY_RE = qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/;
my %KEEP_TOP = map { $_ => 1 } qw(ledger.md inflight.md);
# a checkpoint sweep folder (checkpoint.pm, postcompact.pm without a copy) and a main summary copy
# (copies.pm: <stamp>_<sid8>_c<seq>-<id6>[-N].md) or an unattributed one (compact/unattributed/
# <stamp>_<sid8>_<id6>[-N].md): each carries the session's sid8 and the id6
my $SWEEP_RE = qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_([0-9a-f]{8})-([0-9a-z]{6})-evidence\z/;
my $MAIN_COPY_RE = qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_([0-9a-f]{8})_c[0-9]+-([0-9a-z]{6})(?:-[0-9]+)?\z/;
my $UNATTR_COPY_RE = qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_([0-9a-f]{8})_([0-9a-z]{6})(?:-[0-9]+)?\z/;

sub _size {
    my ($b) = @_;
    $b //= 0;
    return sprintf('%.1f MB', $b / 1048576) if $b >= 1048576;
    return sprintf('%d KB', int(($b + 1023) / 1024)) if $b > 0;
    return '0 KB';
}

sub _show { my ($p) = @_; return skills::util::abbrev_home($p) }

# _dirs(dir) -> names of the real (not linked) subfolders, dot names skipped.
sub _dirs {
    my ($dir) = @_;
    return grep { !/\A\./ && !-l "$dir/$_" && -d _ } skills::util::list_dir($dir);
}

# _real(path) -> the path with its folder's links resolved (the file itself not followed).
sub _real {
    my ($p) = @_;
    my ($d, $b) = $p =~ m{\A(.*)/([^/]+)\z} or return $p;
    my $rd = skills::util::abs_path($d eq '' ? '/' : $d);
    return defined $rd ? "$rd/$b" : $p;
}

sub _forms { my ($p) = @_; my $r = _real($p); return $r eq $p ? ($p) : ($p, $r) }

# _newest(dir) -> the latest mtime of the folder and of everything in it (links not followed).
sub _newest {
    my ($dir) = @_;
    my $ep = (lstat $dir)[9] // 0;
    my @stack = ($dir);
    while (defined(my $d = pop @stack)) {
        for my $e (skills::util::list_dir($d)) {
            my @st = lstat "$d/$e" or next;
            $ep = $st[9] if $st[9] > $ep;
            push @stack, "$d/$e" if -d _;
        }
    }
    return $ep;
}

# ---------------------------------------------------------------- the store's documents

# _docs(handoff-layout root, acc): handoffs (bucket top level) and summary copies (compact/…), and the
# evidence rows of unpublished drafts (.staging/<run>/evidence.jsonl).
sub _docs {
    my ($root, $acc) = @_;
    for my $repo (_dirs($root)) {
        for my $b (_dirs("$root/$repo")) {
            my $bucket = "$root/$repo/$b";
            my @files = map { [ "$bucket/$_", 'handoff' ] } grep { /\.md\z/ && !-l "$bucket/$_" && -f _ } skills::util::list_dir($bucket);
            for my $sub ('compact', 'compact/subagents', 'compact/unattributed') {
                push @files, map { [ "$bucket/$sub/$_", ($sub eq 'compact' ? 'main' : $sub eq 'compact/unattributed' ? 'unattr' : 'copy') ] }
                             grep { /\.md\z/ && !-l "$bucket/$sub/$_" && -f _ } skills::util::list_dir("$bucket/$sub");
            }
            for my $f (@files) {
                my ($path, $where) = @$f;
                my $d = skills::store::read_doc($path) or next;
                my $kind = $d->{fm}{kind} // '';
                my $is = $where eq 'handoff' ? ($kind eq 'handoff' || $kind eq '' ? 'handoff' : undef) : 'copy';
                next unless $is;
                push @{ $acc->{docs} }, { path => $path, stem => skills::store::stem_of($path), kind => $is,
                                          bucket => $bucket, key => "$repo/$b", text => $d->{text}, slot => $where,
                                          epoch => $d->{epoch} // (stat $path)[9] // 0 };
            }
            # an unpublished draft's evidence rows (D-15), with the draft's date (the latest of its begin
            # date in settings.json and the mtimes of its folder and of everything in it, so a draft
            # still being worked on is young): a draft newer than the age keeps them
            for my $st (skills::util::list_dir("$bucket/.staging")) {
                my $dir = "$bucket/.staging/$st";
                next if -l $dir || !-d _ || -e "$dir/published";
                my $t = skills::util::read_text("$dir/evidence.jsonl", $TEXT_MAX) // next;
                my $set = eval { skills::util::json_decode(skills::util::read_file("$dir/settings.json", 65536)) };
                my $ep = _newest($dir);
                my $be = ref $set eq 'HASH' && !ref $set->{date} ? skills::util::iso_to_epoch($set->{date}) : undef;
                $ep = $be if defined $be && $be > $ep;
                my @c;
                for my $l (split /\n/, $t) {
                    my $j = eval { skills::util::json_decode($l) };
                    push @c, _forms($j->{copy}) if ref $j eq 'HASH' && defined $j->{copy} && !ref $j->{copy};
                }
                push @{ $acc->{drafts} }, { epoch => $ep, copies => \@c };
            }
        }
    }
}

# _cite(acc, ctx, doc): what a young document cites stays: its MANIFEST rows, and the paths in its text.
sub _cite {
    my ($acc, $ctx, $d) = @_;
    if ($d->{kind} eq 'handoff') {
        my $rows = skills::store::read_manifest(skills::store::manifest_path($d->{path})) || [];
        for my $r (@$rows) {
            my $c = $r->{copy_path} // '';
            next if $c eq '';
            $acc->{cited}{$_} = 1 for _forms($c), _forms(skills::ctx::follow($ctx, $c));
        }
    }
    my $t = $d->{text};
    my @p;
    # a path in the text, ~/, $HOME/ and ${HOME}/ read as the home folder, ./evidence/ as evidence/
    push @p, $1 while $t =~ m{(?<![\w.~/-])(?:\./)?((?:~/|\$HOME/|\$\{HOME\}/|/|evidence/)[^\s`'"<>()\[\]{}|,;*]+)}g;
    # a path in backticks, double or single quotes may hold spaces
    push @p, $2 while $t =~ m{([`"'])(?:\./)?((?:~/|\$HOME/|\$\{HOME\}/|/|evidence/)(?:(?!\1).)*?)\1}g;
    for my $raw (@p) {
        # the path as written, and without a line reference (log:120, log:120-130, log:120:5,
        # file.rb#L12-L20)
        (my $p = $raw) =~ s{[.:!?]+\z}{};
        _cite_path($acc, $d, $p);
        next unless $p =~ s{(?::[0-9]+(?:[-–][0-9]+)?){1,2}\z|#L[0-9]+(?:-L?[0-9]+)?\z}{};
        $p =~ s{[.:!?]+\z}{};
        _cite_path($acc, $d, $p);
    }
}

sub _cite_path {
    my ($acc, $d, $p) = @_;
    my $home = skills::util::env('HOME') // '';
    $p =~ s{/+\z}{};
    return if $p eq '' || $p eq '~';
    $p =~ s{\A(?:~|\$HOME|\$\{HOME\})(?=/)}{$home} if $home ne '';
    $p = "$d->{bucket}/$p" if $p =~ m{\Aevidence/};
    $acc->{cited}{$_} = 1 for _forms($p);
}

# ---------------------------------------------------------------- units

sub _unit_files {
    my ($u) = @_;
    my @stack = ('');
    my @out;
    while (@stack) {
        my $rel = pop @stack;
        my $dir = $rel eq '' ? $u->{path} : "$u->{path}/$rel";
        for my $e (skills::util::list_dir($dir)) {
            my $r = $rel eq '' ? $e : "$rel/$e";
            my $p = "$u->{path}/$r";
            my @st = lstat $p;
            next unless @st;
            if (-l _ || (!-f _ && !-d _)) { push @out, { rel => $r, path => $p, bytes => 0, keep => 'link' }; next }
            if (-d _) { push @stack, $r; next }
            push @out, { rel => $r, path => $p, bytes => $st[7], mtime => $st[9] };
        }
    }
    return \@out;
}

sub _handoff_text {
    my ($p) = @_;
    return 0 unless $p =~ /\.md\z/;
    my $t = skills::util::read_text($p, 8192) // return 0;
    my $d = skills::store::parse($t);
    my $k = $d->{fm}{kind} // '';
    return ($k eq 'handoff' || $k eq 'compact-summary') ? 1 : 0;
}

sub _cited {
    my ($acc, $u, $f) = @_;
    my $cited = $acc->{cited};
    for my $form (_forms($f->{path})) { return 1 if $cited->{$form} }
    my $p = $f->{path};
    while ($p =~ s{/[^/]+\z}{} && length($p) >= length($u->{path})) {
        for my $form (_forms($p)) { return 1 if $cited->{$form} }
    }
    return 0;
}

# _judge(acc, unit): each file's keep reason (or none: delete), the unit's sizes and age.
sub _judge {
    my ($acc, $u) = @_;
    my $files = _unit_files($u);
    my ($all, $free, $newest) = (0, 0, undef);
    for my $f (@$files) {
        $all += $f->{bytes};
        $newest = $f->{mtime} if defined $f->{mtime} && (!defined $newest || $f->{mtime} > $newest);
        next if $f->{keep};
        if ($f->{rel} eq 'MANIFEST.tsv') { $f->{keep} = 'manifest' }
        elsif ($u->{kind} eq 'evidence' && $KEEP_TOP{ $f->{rel} }) { $f->{keep} = 'ledger' }
        elsif (_handoff_text($f->{path})) { $f->{keep} = 'handoff' }
        elsif (_cited($acc, $u, $f)) { $f->{keep} = 'cited' }
        $free += $f->{bytes} unless $f->{keep};
    }
    $u->{files} = $files;
    $u->{bytes} = $all;
    $u->{free} = $free;
    $u->{epoch} = $u->{owner} ? $u->{owner}{epoch} : $newest // (stat $u->{path})[9] // 0;
    $u->{cited} = [ grep { ($_->{keep} // '') eq 'cited' } @$files ];
    $u->{drop} = [ grep { !$_->{keep} } @$files ];
    return $u;
}

sub _units_handoff {
    my ($root, $acc, $ro) = @_;
    my @u;
    for my $repo (_dirs($root)) {
        for my $b (_dirs("$root/$repo")) {
            my $bucket = "$root/$repo/$b";
            next if -l "$bucket/evidence";
            for my $stem (_dirs("$bucket/evidence")) {
                my $owner = $acc->{by_path}{"$bucket/$stem.md"};
                push @u, { kind => 'evidence', path => "$bucket/evidence/$stem", stem => $stem, key => "$repo/$b",
                           owner => $owner, ro => $ro };
            }
        }
    }
    return @u;
}

sub _units_disposable {
    my ($root, $acc, $ro) = @_;
    my @u;
    for my $day (grep { $_ =~ $DAY_RE } _dirs($root)) {
        for my $name (_dirs("$root/$day")) {
            (my $stem = $name) =~ s/-evidence\z//;
            my $owner = $name eq 'stash' ? undef : $acc->{by_stem}{$stem};
            # a sweep named at checkpoint time (<stamp>_<sid8>-<id6>-evidence) belongs to the main
            # summary copy of that session and id6 (else its unattributed copy), saved later under
            # its own stamp
            $owner //= $acc->{by_sweep}{"$1-$2"} if $name =~ $SWEEP_RE;
            push @u, { kind => 'disposable', path => "$root/$day/$name", day => $day, stem => $stem,
                       key => ($owner ? $owner->{key} : undef), owner => $owner, stash => ($name eq 'stash' ? 1 : 0), ro => $ro };
        }
    }
    return @u;
}

sub _owner_text {
    my ($u) = @_;
    return 'stash copies' if $u->{stash};
    my $o = $u->{owner};
    return $u->{kind} eq 'evidence' ? 'no handoff file' : 'no handoff or summary copy found' unless $o;
    my $name = $o->{path} =~ m{([^/]+)\z} ? $1 : $o->{path};
    return ($o->{kind} eq 'handoff' ? 'handoff ' : 'summary copy ') . $name;
}

sub _line {
    my ($u, $root, $days_now) = @_;
    my $age = int(($days_now - $u->{epoch}) / 86400);
    my $rel = index($u->{path}, "$root/") == 0 ? substr($u->{path}, length($root) + 1) : _show($u->{path});
    my @kept = @{ $u->{cited} };
    my $kb = 0;
    $kb += $_->{bytes} for @kept;
    return sprintf('  %dd · %s · %s · %s · %s/', $age, _size($u->{free}), $u->{key} // '-', _owner_text($u), $rel)
           . (@kept ? sprintf(' (kept: %d cited %s, %s)', scalar @kept, @kept == 1 ? 'file' : 'files', _size($kb)) : '');
}

# ---------------------------------------------------------------- MANIFEST rows

# _manifests(writable handoff root, writable disposable root) -> every MANIFEST.tsv prune may rewrite.
sub _manifests {
    my ($root, $disp) = @_;
    my @m;
    for my $repo (_dirs($root)) {
        for my $b (_dirs("$root/$repo")) {
            my $e = "$root/$repo/$b/evidence";
            next if -l $e;
            push @m, grep { !-l $_ && -f $_ } map { "$e/$_/MANIFEST.tsv" } _dirs($e);
        }
    }
    if (defined $disp) {
        for my $day (grep { $_ =~ $DAY_RE } _dirs($disp)) {
            push @m, grep { !-l $_ && -f $_ } map { "$disp/$day/$_/MANIFEST.tsv" } _dirs("$disp/$day");
        }
    }
    return @m;
}

# _mark(ctx, manifests, {path form => 1}, scan or undef, {manifest => {line => scan}}) -> rows changed.
# With a scan: rows whose copy is in the set get it, their old scan saved in the undo map. Without:
# the undo map's rows whose copy is in the set get their old scan back.
sub _mark {
    my ($ctx, $mans, $set, $scan, $undo) = @_;
    my $n = 0;
    for my $m (@$mans) {
        next if !defined $scan && !$undo->{$m};
        my $raw = skills::util::read_text($m) // next;
        my @l = split /\n/, $raw, -1;
        my $changed = 0;
        for my $i (0 .. $#l) {
            next if $l[$i] eq '' || $l[$i] =~ /\Acopy_path\t/;
            my @f = split /\t/, $l[$i], -1;
            next unless @f >= 8 && $f[0] ne '-' && $f[0] ne '';
            my $hit = grep { $set->{$_} } _forms($f[0]), _forms(skills::ctx::follow($ctx, $f[0]));
            next unless $hit;
            if (defined $scan) {
                next if $f[7] eq $scan;
                $undo->{$m}{$i} = $f[7];
                $f[7] = $scan;
            } else {
                next unless exists $undo->{$m}{$i};
                $f[7] = $undo->{$m}{$i};
            }
            $l[$i] = join("\t", @f);
            $changed++;
        }
        next unless $changed;
        my $mode = ((lstat $m)[2] // 0600) & 07777;
        skills::util::write_replace($m, join("\n", @l), $mode);
        $n += $changed;
    }
    return $n;
}

# ---------------------------------------------------------------- run

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'days=s', 'min-mb=s', 'root=s@', 'apply', 'plan=s', 'all');
    die skills::cli::usage('prune [--days N] [--min-mb N] [--root DIR]... [--all] [--apply --plan H]') if @$argv;
    my $ctx = skills::ctx::new({});
    my $kd = $ctx->{settings}{disposable_keep_days};
    my ($days, $why);
    if (defined $o->{days}) {
        die skills::cli::usage('--days takes a whole number of days, 1 or more') unless $o->{days} =~ /\A[1-9][0-9]{0,4}\z/;
        ($days, $why) = (0 + $o->{days}, '--days');
    } elsif (defined $kd && $kd =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $kd >= 1) {
        ($days, $why) = (int $kd, 'disposable_keep_days');
    } else {
        ($days, $why) = ($DEFAULT_DAYS, 'the default; disposable_keep_days is ' . (defined $kd && $kd =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $kd > 0 ? 'under 1 day' : '0'));
    }
    my $min = $o->{'min-mb'} // 0;
    die skills::cli::usage('--min-mb takes a number of MB, 0 or more') unless $min =~ /\A[0-9]{1,6}(?:\.[0-9]+)?\z/;
    my $apply = $o->{apply} ? 1 : 0;
    die skills::cli::usage('--plan goes with --apply') if defined $o->{plan} && !$apply;
    # --apply deletes only what a dry run listed: the plan printed there
    die skills::cli::usage('--apply takes --plan H, the hash the dry run printed') if $apply && !defined $o->{plan};
    if ($apply) {
        my $rr = skills::core::roots_check($ctx->{settings});
        die skills::cli::refuse($rr) if $rr;
    }
    my $now = skills::util::now();
    my $cut = $now - $days * 86400;

    # the folders: [label, path, layout, read-only]
    my @roots = (['handoff_root', $ctx->{root}, 'handoff', 0], ['disposable_root', $ctx->{disposable}, 'disposable', 0]);
    my $dl = defined &rc::disposable_legacy ? rc::disposable_legacy() : undef;
    push @roots, ['old handoff folder', $ctx->{legacy}, 'handoff', 1] if defined $ctx->{legacy};
    push @roots, ['old evidence folder', $dl, 'disposable', 1] if defined $dl;
    my @notes;
    for my $r (@{ $o->{root} || [] }) {
        my $p = skills::util::abs_path($r);
        if (!defined $p || !-d $p) { push @notes, "--root " . _show($r) . ': not a folder, skipped'; next }
        my $rp = skills::util::abs_path($p) // $p;
        my ($same) = grep { defined $_->[1] && (skills::util::abs_path($_->[1]) // $_->[1]) eq $rp } @roots;
        if ($same) { push @notes, "--root " . _show($p) . ": the $same->[0], listed once"; next }
        my $layout = (grep { $_ =~ $DAY_RE } _dirs($p)) ? 'disposable' : 'handoff';
        push @roots, ['folder', $p, $layout, 1];
    }
    @roots = grep { defined $_->[1] && -d $_->[1] } @roots;

    my %acc = (docs => [], cited => {});
    my %unattr;
    _docs($_->[1], \%acc) for grep { $_->[2] eq 'handoff' } @roots;
    for my $d (sort { ($a->{kind} eq 'handoff' ? 0 : 1) <=> ($b->{kind} eq 'handoff' ? 0 : 1) } @{ $acc{docs} }) {
        $acc{by_stem}{ $d->{stem} } //= $d;
        $acc{by_path}{ $d->{path} } = $d if $d->{kind} eq 'handoff';
        $acc{by_sweep}{"$1-$2"} //= $d if $d->{slot} eq 'main' && $d->{stem} =~ $MAIN_COPY_RE;
        $unattr{"$1-$2"} //= $d if $d->{slot} eq 'unattr' && $d->{stem} =~ $UNATTR_COPY_RE;
        _cite(\%acc, $ctx, $d) if $d->{epoch} > $cut;
    }
    $acc{by_sweep}{$_} //= $unattr{$_} for keys %unattr;
    $acc{cited}{$_} = 1 for map { @{ $_->{copies} } } grep { $_->{epoch} > $cut } @{ $acc{drafts} || [] };
    my $young = grep { $_->{epoch} > $cut } @{ $acc{docs} };

    my @out = ($apply ? 'prune: deleting the files listed'
                      : 'prune: dry run, nothing deleted (the apply on the plan line deletes the files listed)');
    push @out, "age: older than $days days ($why) · size: " . ($min > 0 ? "$min MB or more" : 'any')
               . ' · never deleted: handoff files, summary copies, MANIFEST.tsv, ledger.md, inflight.md, and what a newer handoff cites';
    push @out, @notes;
    my (%tot, @drop, @ro_lines);
    $tot{$_} = 0 for qw(units free ro_units ro_free cited cited_b);
    for my $r (@roots) {
        my ($label, $root, $layout, $ro) = @$r;
        my @u = map { _judge(\%acc, $_) } ($layout eq 'handoff' ? _units_handoff($root, \%acc, $ro) : _units_disposable($root, \%acc, $ro));
        @u = grep { $_->{epoch} <= $cut && $_->{bytes} >= $min * 1048576 && @{ $_->{drop} } } @u;
        @u = sort { $b->{free} <=> $a->{free} || $a->{path} cmp $b->{path} } @u;
        my $free = 0;
        $free += $_->{free} for @u;
        my $head = "$label " . _show($root) . ($ro ? ' (read-only: listed, never deleted)' : '') . ': '
                   . scalar(@u) . (@u == 1 ? ' folder, ' : ' folders, ') . _size($free) . ($ro ? '' : ' to free');
        push @out, $head;
        my @l = map { _line($_, $root, $now) } @u;
        my $max = $o->{all} ? scalar @l : $LIST_MAX;
        push @out, @l[0 .. ($#l < $max - 1 ? $#l : $max - 1)];
        if (@l > $max) {
            my $rest = 0;
            $rest += $_->{free} for @u[$max .. $#u];
            push @out, sprintf('  (+%d smaller %s, %s, %s; --all lists them)', @l - $max, @l - $max == 1 ? 'folder' : 'folders', _size($rest), $ro ? 'listed only' : 'deleted with the rest');
        }
        if ($ro) { $tot{ro_units} += @u; $tot{ro_free} += $free; next }
        $tot{units} += @u;
        $tot{free} += $free;
        for my $x (@u) {
            push @drop, @{ $x->{drop} };
            $tot{cited} += @{ $x->{cited} };
            $tot{cited_b} += $_->{bytes} for @{ $x->{cited} };
            push @{ $tot{dirs} }, $x;
        }
    }
    # 0.1.7 (D-81): the cache state files (lib/cachestate.pm) of sessions that ended, or with no end
    # were not written, over 7 days ago, whatever --days says
    my @cache = cachestate::stale($now);
    if (@cache) {
        my $b = 0;
        $b += $_->{bytes} for @cache;
        push @out, sprintf('cache state %s: %d %s of sessions ended or not written over %d days ago, %s to free', _show(cachestate::dir()),
                           scalar @cache, @cache == 1 ? 'file' : 'files', $cachestate::PRUNE_DAYS, _size($b));
        push @drop, @cache;
        $tot{free} += $b;
    }
    my $plan = substr(skills::util::sha256_hex(join('', map { "$_->{path}\t$_->{bytes}\t$_->{mtime}\n" } sort { $a->{path} cmp $b->{path} } @drop)), 0, 12);
    push @out, sprintf('total: %d %s, %d files, %s to free', $tot{units}, $tot{units} == 1 ? 'folder' : 'folders', scalar @drop, _size($tot{free}))
               . ($tot{cited} ? sprintf(' · kept: %d %s (%s) that a handoff or unpublished draft newer than %d days cites', $tot{cited}, $tot{cited} == 1 ? 'file' : 'files', _size($tot{cited_b}), $days) : '')
               . ($tot{ro_units} ? sprintf(' · %s more in read-only folders, not deleted', _size($tot{ro_free})) : '');
    push @out, "handoffs and summary copies newer than $days days: $young";
    if (!$apply) {
        push @out, @drop ? "plan: $plan (apply: prune --apply --plan $plan, with the same --days, --min-mb and --root)" : 'nothing to prune';
        skills::cli::say($_) for @out;
        return 0;
    }
    die skills::cli::refuse('plan-changed', "the dry run's plan was $o->{plan}, now $plan: run the dry run again")
        if defined $o->{plan} && $o->{plan} ne $plan;

    my %set = map { ($_ => 1) } map { _forms($_->{path}) } @drop;
    my @mans = _manifests($ctx->{root}, $ctx->{disposable});
    my %undo;
    my $marked = _mark($ctx, \@mans, \%set, 'pruned', \%undo);
    my ($gone, $gone_b, @failed) = (0, 0);
    for my $f (@drop) {
        my @st = lstat $f->{path};
        if (!@st) { $gone++; next }
        if (-l _ || !-f _ || $st[7] != $f->{bytes} || $st[9] != $f->{mtime}) { push @failed, [ $f, 'changed' ]; next }
        if (unlink $f->{path}) { $gone++; $gone_b += $f->{bytes}; next }
        (my $e = "$!") =~ s/\s+\z//;
        push @failed, [ $f, $e ];
    }
    if (@failed) {
        my %back = map { ($_ => 1) } map { _forms($_->[0]{path}) } @failed;
        $marked -= _mark($ctx, \@mans, \%back, undef, \%undo);
    }
    # the folders left empty, deepest first (rmdir only), then an empty dated folder
    for my $u (@{ $tot{dirs} || [] }) {
        my %d;
        for my $f (@{ $u->{files} }) { my $r = $f->{rel}; $d{$r} = 1 while $r =~ s{/[^/]+\z}{} }
        rmdir "$u->{path}/$_" for sort { length($b) <=> length($a) } keys %d;
        rmdir $u->{path};
        rmdir $u->{path} =~ s{/[^/]+\z}{}r if $u->{kind} eq 'disposable';
    }
    push @out, sprintf('deleted: %d files, %s · MANIFEST rows marked pruned: %d · failed: %d', $gone, _size($gone_b), $marked, scalar @failed);
    push @out, map { '  failed: ' . _show($_->[0]{path}) . " ($_->[1])" } @failed[0 .. ($#failed < 9 ? $#failed : 9)];
    push @out, 'read-only folders: nothing deleted there' if $tot{ro_units};
    skills::cli::say($_) for @out;
    return @failed ? 3 : 0;
}

1;

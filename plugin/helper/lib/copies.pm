package copies;
# lib/copies.pm: summary copies (MOD-SPEC §5.3 step 3, §7; OD-11, OD-12). Owner: WP-core.
#   main    -> <bucket>/compact/<stamp>_<sid8>_c<seq>-<id6>.md
#   sub     -> <bucket>/compact/subagents/<stamp>_<sid8>[-a<agent8>]_c<seq>-<id6>.md
#   unknown -> <bucket>/compact/unattributed/<stamp>_<sid8>_<id6>.md
# <id6> = nonce6, or h + 5 hex of the normalized body's sha256. One copy per id6:
# an existing file is verified by sha (EXISTS sha-match / sha-differs), never
# replaced; a true h-id collision with other content gets -2. seq under seq.lock.
# Mode 0400; frontmatter from the dispatch record and the boundary row only.
use strict;
use warnings;

our @SLOTS = ('compact', 'compact/subagents', 'compact/unattributed');

sub slot_dir {
    my ($bucket, $scope) = @_;
    return "$bucket/compact" if $scope eq 'main';
    return "$bucket/compact/subagents" if $scope eq 'sub';
    return "$bucket/compact/unattributed";
}

sub id6 {
    my ($nonce, $sha) = @_;
    return substr($nonce, 0, 6) if nonce::valid($nonce);
    return 'h' . substr($sha, 0, 5);
}

# find(bucket, id6) -> path of the copy carrying this id6, or undef
sub find {
    my ($bucket, $id6) = @_;
    for my $s (@SLOTS) {
        for my $f (util::list_dir("$bucket/$s")) {
            return "$bucket/$s/$f" if $f =~ /[-_]\Q$id6\E\.md$/;
        }
    }
    return undef;
}

# body sha of an existing copy (the original's sha when the copy is redacted)
sub copy_sha {
    my ($path) = @_;
    my $raw = util::read_file($path) // return (undef, {});
    my ($fm, $body) = frontmatter::read($raw);
    return (undef, {}) unless $fm;
    if (defined $fm->{redacted} && $fm->{redacted} =~ /sha256 ([0-9a-f]{64})/) { return ($1, $fm) }
    $body =~ s/\n\z//;
    return (sha::hex256($body), $fm);
}

sub _seq {
    my ($dir, $sid8, $actor_tag) = @_;
    my $n = 0;
    for my $f (util::list_dir($dir)) {
        $n++ if $f =~ /^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_\Q$sid8\E\Q$actor_tag\E_c\d+-/;
    }
    return $n + 1;
}

# session_copies(sid, actor) -> [{path, date, epoch}] across <root>/*/*/compact/
sub session_copies {
    my ($sid, $actor, $extra_bucket) = @_;
    my $root = rc::root();
    my $sid8 = substr($sid, 0, 8);
    my %b;
    for my $repo (util::list_dir($root)) {
        next if $repo =~ /^\./;
        for my $top (util::list_dir("$root/$repo")) {
            next if $top =~ /^\./;
            $b{"$root/$repo/$top"} = 1 if -d "$root/$repo/$top/compact";
        }
    }
    $b{$extra_bucket} = 1 if defined $extra_bucket && -d "$extra_bucket/compact";
    my @out;
    for my $bk (sort keys %b) {
        my $dir = $actor eq 'main' ? "$bk/compact" : "$bk/compact/subagents";
        for my $f (util::list_dir($dir)) {
            next unless $f =~ /^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_\Q$sid8\E(?:-a[0-9A-Za-z]+)?_c\d+-[0-9a-z-]+\.md$/;
            my $raw = util::read_file("$dir/$f", 8192) // next;
            my ($fm) = frontmatter::read($raw . ($raw =~ /\n---\n/ ? '' : "\n---\n"));
            next unless $fm && ($fm->{session_id} // '') eq $sid;
            next if $actor eq 'main' && ($fm->{actor} // '') ne 'main';
            push @out, { path => "$dir/$f", date => $fm->{date}, epoch => util::parse_iso($fm->{date} // '') // 0, fm => $fm };
        }
    }
    return [sort { $a->{epoch} <=> $b->{epoch} || $a->{path} cmp $b->{path} } @out];
}

sub prev_copy {
    my ($sid, $bucket) = @_;
    my $c = session_copies($sid, 'main', $bucket);
    return @$c ? $c->[-1]{path} : undef;
}

# save(%a) -> {exit, line1, line2, result, path, verdict, id6, sha256}
# a: sid text nonce writer scope agent tokens cwd transcript trigger dispatch
#    seat_state channel precomputed scan verdict_ctx late queue_lane evidence where
sub save {
    my (%a) = @_;
    my $sid = $a{sid};
    my $s = $a{scan} || detect::scan($a{text});
    $s->{sha256} //= sha::hex256($s->{normalized});
    my $nonce = nonce::valid($a{nonce}) ? $a{nonce} : $s->{nonce};
    $nonce = undef unless nonce::valid($nonce);
    my $rec = $a{dispatch} // (defined $nonce ? dispatch::read(rc::watch(), $sid, $nonce) : undef);
    my $scope = $a{scope} // 'unknown';
    my %vc = %{ $a{verdict_ctx} || {} };
    $vc{scope} //= $scope;
    $vc{precomputed} //= $a{precomputed};
    my $verdict = $a{verdict} // detect::verdict($s, %vc);
    my $vline = detect::verdict_line($s, $verdict);
    my $id6 = id6($nonce, $s->{sha256});
    my %ret = (verdict => $verdict, id6 => $id6, sha256 => $s->{sha256}, line1 => $vline, nonce => $nonce);

    my $refuse = sub {
        my ($why) = @_;
        rc::emit('copy', [nonce => $nonce, id6 => $id6, result => "failed:$why", slot => undef, rel_path => undef, writer => $a{writer}]);
        return { %ret, exit => 3, result => "failed:$why", line2 => "REFUSED: $why" };
    };
    return $refuse->(rc::root_reason('handoff_root') // 'root-unsafe') unless rc::root_ok('handoff_root');
    return $refuse->('no-watch') unless defined rc::watch();

    my $where = $a{where} || git::where($a{cwd});
    my $bk = bucket::resolve($sid, $a{cwd}, undef, $where);
    my $dir = slot_dir($bk->{path}, $scope);
    my $sid8 = substr($sid, 0, 8);
    my $actor = $scope eq 'main' ? 'main' : $scope eq 'sub' ? ($a{agent} // 'sub-unknown') : 'unknown';
    my $actor_tag = ($scope eq 'sub' && defined $a{agent} && $a{agent} =~ /^[A-Za-z0-9]/) ? '-a' . substr($a{agent}, 0, 8) : '';

    # Secret scan of the summary before writing (S-10): a HARD hit -> redacted copy.
    my $body = $s->{normalized};
    my $redacted;
    my $hits = secrets::scan($body);
    if (secrets::has_hard($hits)) {
        my ($red, $rh) = secrets::redact($body, ['HARD']);
        my $n = 0;
        $n += $_->{count} for @$rh;
        $redacted = sprintf('%d (%s); sha256 %s', $n, secrets::rule_ids($rh), $s->{sha256});
        $body = $red;
    }
    $ret{secret_hits} = [map { $_->{rule} } @$hits];

    my $owner = { sid => $sid, actor => $actor };
    my $sid_dir = rc::sid_dir();
    my $prev = prev_copy($sid, $bk->{path});
    my $lin = sessions::lineage($sid) || {};
    my $c = rc::claude();
    my $tb = ref $a{tokens} eq 'ARRAY' ? $a{tokens}[0] : undef;
    my $ta = ref $a{tokens} eq 'ARRAY' ? $a{tokens}[1] : undef;
    my $out = eval {
        lock::with("$sid_dir/seq.lock", $owner, sub {
            my $cur = $id6;
            for my $try (1 .. 9) {
                my $existing = find($bk->{path}, $cur);
                last unless $existing;
                my ($esha, $efm) = copy_sha($existing);
                if (defined $esha && $esha eq $s->{sha256}) {
                    return { kind => 'exists', path => $existing, match => 1, fm => $efm };
                }
                if ($cur =~ /^h/) { $cur = $id6 . '-' . ($try + 1); next }    # true collision, other content
                return { kind => 'exists', path => $existing, match => 0, fm => $efm };
            }
            my $seq = $scope eq 'unknown' ? undef : _seq($dir, $sid8, $actor_tag);
            my $stamp = util::stamp(util::now());
            my $name = $scope eq 'unknown' ? "${stamp}_${sid8}_$cur.md" : "${stamp}_${sid8}${actor_tag}_c${seq}-$cur.md";
            my $path = "$dir/$name";
            my $fm = frontmatter::write([
                kind                => ($scope eq 'sub' ? 'subagent-summary' : 'compact-summary'),
                writer              => $a{writer},
                nonce               => $nonce,
                date                => util::iso(util::now()),
                session_id          => $sid,
                actor               => $actor,
                previous_session_id => $lin->{previous_session_id},
                lineage_reason      => $lin->{lineage_reason},
                transcript_path     => $a{transcript},
                claude_pid          => $c->{pid},
                cc_version          => rc::cc_version(),
                repository          => $bk->{repo},
                bucket              => $bk->{rel},
                bucket_source       => $bk->{source},
                worktree            => $where->{toplevel},
                branch              => $where->{branch},
                git_commit          => $where->{head},
                status              => 'in-progress',
                queue_lane          => $a{queue_lane},
                previous_handoff    => (defined $prev ? util::abbrev($prev) : undef),
                trigger             => $a{trigger} // ($rec ? $rec->{trigger} : undef),
                compaction_seq      => $seq,
                tokens_before       => $tb,
                tokens_after        => $ta,
                verdict             => $verdict,
                channel             => $a{channel} // ($rec ? $rec->{channel} : 'none'),
                seat_state          => $a{seat_state},
                evidence            => $a{evidence},
                redacted            => $redacted,
            ]);
            util::mkdir_p($dir);
            my $ok = util::write_excl($path, $fm . $body . "\n", 0400);
            return { kind => 'race', path => $path } unless $ok;
            my $back = util::read_file($path);
            my ($pfm) = frontmatter::read($back);
            return { kind => 'failed', why => 'frontmatter-parse', path => $path } unless $pfm && ($pfm->{session_id} // '') eq $sid;
            return { kind => 'saved', path => $path, seq => $seq, id6 => $cur };
        });
    };
    if (!$out) {
        my $e = $@ // 'error';
        my $why = $e =~ /lock-timeout/ ? 'lock-timeout' : 'write-error';
        return $refuse->($why);
    }
    my $rel = substr($out->{path}, length(rc::root()) + 1);
    my $slot = $scope eq 'main' ? 'main' : $scope eq 'sub' ? 'subagents' : 'unattributed';
    if ($out->{kind} eq 'exists') {
        my $result = $out->{match} ? 'exists' : 'mismatch';
        rc::emit('copy', [nonce => $nonce, id6 => $id6, result => $result, slot => $slot, rel_path => $rel, writer => $a{writer}]);
        my $pv = $out->{fm}{verdict};
        if (($a{writer} // '') eq 'mod' && ($out->{fm}{writer} // '') eq 'postcompact-fallback' && defined $pv && $pv ne $verdict) {
            rc::emit('verdict_mismatch', [nonce => $nonce, postcompact => $pv, after_step => $verdict]);
        }
        return { %ret, exit => 0, result => $result, path => $out->{path}, rel => $rel,
                 line2 => 'EXISTS: ' . util::abbrev($out->{path}) . ($out->{match} ? ' sha-match' : ' sha-differs') };
    }
    return $refuse->($out->{why} // 'race') unless $out->{kind} eq 'saved';
    my $result = $a{late} ? 'late' : $scope eq 'unknown' ? 'unattributed' : 'saved';
    rc::emit('copy', [nonce => $nonce, id6 => $out->{id6}, result => $result, slot => $slot, rel_path => $rel, writer => $a{writer},
                      seq => $out->{seq}, redacted => (defined $redacted ? jsonc::true() : jsonc::false())]);
    rc::emit('verdict', [nonce => $nonce, verdict => $verdict, verdict_source => (($a{writer} // '') eq 'mod' ? 'after-step' : 'postcompact'),
                         marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end}]);
    return { %ret, exit => 0, result => $result, path => $out->{path}, rel => $rel, seq => $out->{seq}, id6 => $out->{id6},
             line2 => 'Saved copy: ' . util::abbrev($out->{path}), bucket => $bk };
}

1;

package skills::begin;
# lib/skills/begin.pm: `begin` (HDN §6; BUILD-PLAN §3.1 row; D-14, RV-18,
# RV-19, RV-26, RV-28, OD-16). Prints one JSON object of at most 3 KB (more only when
# no further cut brings it within 3 KB, see _fit) and creates the stage
# <bucket>/.staging/<sid8>-<nonce>/ (0700) with settings.json.
# 2026-10-21 rulings: the carry base is the newest handoff in the bucket, whoever
# wrote it, with previous_kind own|chain|foreign (small-rulings §2.1; a document with
# imported_from is never the base, DP-6); an open plugin handoff turn of this session
# is bound to the stage, and a second begin for it returns that stage (D-18 B7);
# the D-12 mode and, in repo mode, the export target are printed.
# U-04 (REVIEW-NIGHT-2): the reply names the store root once (`store_root`) and prints the
# other store paths relative to it; `stage` stays whole (a command argument and a Write
# target). Every entry begin knows goes to <stage>/begin-full.json, and a list the reply
# shortens is counted in `trimmed` with that file's path: never a silent cut.
use strict;
use warnings;
use utf8;
use Cwd ();
use File::Basename ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::gitfacts;
use skills::store;

# The HDN §6 keys, plus reuse_window_min (D-14) and store_root (U-04). Exactly these are
# printed. handoff_turn and resumed only when a plugin handoff turn is open (D-18 B8);
# trimmed only when the reply leaves list entries out (U-04); plugin_notice only when sessions
# started since this one run another plugin version (0.1.3, lib/plugver.pm).
our @KEYS = qw(checked_at session repo worktree branch head porcelain ahead behind in_progress
               store_root bucket stem stage nonce previous_handoff previous_kind previous_sid8 previous_stamp
               own_previous_handoff carry_notice next_ids own_latest newer_foreign ownership gsd
               queued_line queue inflight_measured tmp_candidates config reuse_window_min mode export_target);
our $REUSE_WINDOW_MIN = 15;
our $MAX_BYTES = 3072;
# The file in the stage that holds begin's whole reply, every newer_foreign entry included.
our $FULL_NAME = 'begin-full.json';
# The reply shows at most this many in-flight tasks and tmp candidates; begin-full.json has
# them all, and `trimmed.cut` counts the rest (U-04 follow-up: never a silent cap).
our $INFLIGHT_SHOW = 8;
our $TMP_SHOW = 20;
# paths.jsonl is read from its last this many bytes (U-04 follow-up: the older rows are counted).
our $PATHS_READ_MAX = 1024 * 1024;
my $LANE_RE = qr/\A(?:lane|auto):[A-Za-z0-9._\/-]+\z/;

my %FLAG_KEY = (
    root              => 'handoff_root',
    'disposable-root' => 'disposable_root',
    'keep-days'       => 'disposable_keep_days',
    'quota-mb'        => 'evidence_quota_mb',
    'queue-cmd'       => 'queue_cmd',
);

sub slug {
    my ($t) = @_;
    return undef if skills::util::unset_value($t);
    my $s = lc $t;
    $s =~ s/[^a-z0-9]+/-/g;
    $s =~ s/\A-+|-+\z//g;
    $s = substr($s, 0, 48);
    $s =~ s/-+\z//;
    return $s eq '' ? undef : $s;
}

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'sid=s', 'topic=s', 'topic-explicit', 'root=s', 'disposable-root=s',
        'keep-days=s', 'quota-mb=s', 'queue-cmd=s', 'cwd=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    my %flags = map { $FLAG_KEY{$_} => $o->{$_} } grep { exists $o->{$_} } keys %FLAG_KEY;
    my $ctx = skills::ctx::new(\%flags);
    my $refused = skills::core::roots_check($ctx->{settings});
    die skills::cli::refuse($refused) if $refused;

    my $now = skills::util::now();
    my $cwd = skills::util::abs_path($o->{cwd} // skills::util::cwd());
    my $id = skills::ctx::resolve_sid($ctx, $o->{sid});
    my $sid = $id->{sid};
    my $lin = skills::ctx::lineage_of($ctx, $sid) || {};
    my $chain = skills::ctx::chain($ctx, $sid);
    my %chain_sids = map { $_->{sid} => 1 } @$chain;

    my $g = skills::gitfacts::facts($cwd);
    my $topic = slug($o->{topic});

    # Bucket: pin → pin-lineage → branch ticket → topic → general (core seam);
    # --topic-explicit re-pins to the topic after an ownership check (RV-28).
    my $b = skills::core::bucket_resolve($sid, $cwd, $topic, $ctx->{settings});
    my %bucket = (path => $b->{path}, source => $b->{source});
    my $repin;
    if ($o->{'topic-explicit'} && $topic) {
        my $want = "$ctx->{root}/$g->{repo}/$topic";
        if ($want ne $bucket{path}) {
            my $holder = _bucket_holder($ctx, $want, $sid);
            if ($holder) {
                $repin = { result => 'refused', held_by => $holder };
            } else {
                $repin = { result => 'ok', from => _rel($ctx, $bucket{path}) };
                %bucket = (path => $want, source => 'topic-explicit');
            }
        }
    }
    # D-18 B7: the open handoff turn of this session; a stage already bound to it is
    # returned as it is (one handoff per ht), never a second one.
    my $sid_dir = skills::core::sid_dir();
    my $ht = skills::core::ht_open_for_begin($sid_dir);
    my ($nonce, $stage, $stem, $resumed);
    if ($ht) {
        my $bound = skills::core::ht_stage_of($sid_dir, $ht->{ht});
        my $old = _stage_meta($bound);
        if ($old) {
            ($stage, $nonce, $stem, $resumed) = ($bound, $old->{nonce}, $old->{stem}, 1);
            %bucket = (path => $old->{bucket}, source => $old->{bucket_source} // $bucket{source});
        }
    }
    my $bucket = $bucket{path};

    # Stage <bucket>/.staging/<sid8>-<nonce>/
    if (!$stage) {
        for (1 .. 5) {
            $nonce = skills::core::nonce($sid);
            $stage = "$bucket/.staging/$id->{sid8}-$nonce";
            last unless -e $stage;
            undef $stage;
        }
        die "stage: no free nonce\n" unless $stage;
        skills::util::mkdir_p("$bucket/.staging");
        mkdir($stage, 0700) or die "stage $stage: $!\n";
        chmod 0700, $stage;
        $stem = skills::util::stem_time($now) . '_' . $id->{sid8} . '_' . ($topic // slug(File::Basename::basename($bucket)) // 'handoff');
        if ($ht) {
            my ($bound, $was) = skills::core::ht_bind_stage($sid_dir, $ht->{ht}, $stage);
            my $old = $was ? _stage_meta($bound) : undef;
            if ($old) {
                # Another begin bound this ht first: use its stage; ours stays empty.
                ($stage, $nonce, $stem, $resumed) = ($bound, $old->{nonce}, $old->{stem}, 1);
                %bucket = (path => $old->{bucket}, source => $old->{bucket_source} // $bucket{source});
                $bucket = $bucket{path};
            }
        }
    }

    # Carry base (small-rulings §2.1, RV-19 refined): the newest handoff in the bucket by
    # frontmatter date, name as tiebreak, whoever wrote it; never one with imported_from.
    # own_chain = this session or a lineage predecessor (A-6, 3 hops). STATE-ROOT: the bucket's twin in the
    # legacy root counts too (read only; the stage and the handoff go to the store root's bucket).
    my $docs = [ sort _newest_first grep { skills::store::is_handoff($_) }
                  map { @{ skills::store::docs_in($_) } } @{ skills::store::twin_buckets($ctx, $bucket) } ];
    my $is_own = sub { ($_[0]{fm}{session_id} // '') eq $sid };
    my $is_pred = sub { $chain_sids{ $_[0]{fm}{session_id} // '' } ? 1 : 0 };
    my @cands = grep { !skills::store::imported($_) } @$docs;
    my @own = grep { $is_own->($_) } @cands;
    my @pred = grep { $is_pred->($_) } @cands;
    my @own_chain = grep { $is_own->($_) || $is_pred->($_) } @cands;
    my $base = $cands[0];
    my $kind = !$base ? undef : $is_own->($base) ? 'own' : $is_pred->($base) ? 'chain' : 'foreign';
    my $own_prev = ($kind // '') eq 'foreign' ? $own_chain[0] : undef;
    my $prev = $own_chain[0];    # the own chain's latest file: the commit base (D-21)
    my %carry = (
        previous_kind        => $kind,
        previous_sid8        => ($base ? skills::ctx::sid8($base->{fm}{session_id}) : undef),
        previous_stamp       => ($base ? _doc_stamp($base) : undef),
        own_previous_handoff => ($own_prev ? $own_prev->{path} : undef),
        carry_notice         => undef,
        next_ids             => next_ids(grep { defined } $base, $own_prev),
    );
    if (($kind // '') eq 'foreign') {
        $carry{carry_notice} = sprintf("not your chain: the newest handoff here is %s's (%s)", $carry{previous_sid8} || 'unknown', $carry{previous_stamp} // 'undated')
            . ($own_prev ? sprintf('; yours is %s (%s)', skills::store::stem_of($own_prev->{path}), _doc_stamp($own_prev) // 'undated') : '');
    }
    my $own_latest;
    if ($own[0]) {
        my $d = $own[0];
        my $pin = skills::ctx::pin_read($ctx, $sid) || {};
        my $last = ref $pin->{last_handoff} eq 'HASH' ? $pin->{last_handoff} : {};
        my $wh = $g->{in_git} ? skills::gitfacts::work_hash($g->{worktree}) : undef;
        my $unchanged = ($last->{path} // '') eq $d->{path}
            && defined $last->{head} && defined $g->{head_full} && $last->{head} eq $g->{head_full}
            && defined $last->{work_hash} && defined $wh && $last->{work_hash} eq $wh ? 1 : 0;
        $unchanged = 1 if !$g->{in_git} && ($last->{path} // '') eq $d->{path} && !defined $last->{head};
        my $age = defined $d->{epoch} ? int(($now - $d->{epoch}) / 60) : undef;
        $own_latest = { path => $d->{path}, date => $d->{fm}{date}, age_min => $age,
                        unchanged => ($unchanged ? \1 : \0) };
    }
    # newer_foreign: other sessions' files newer than the own chain's latest, minus the
    # base, which is read in full (up to 2 more when the base is foreign). The reply shows
    # the newest of them; begin-full.json holds them all (U-04). Paths relative to the root.
    my $since = $own[0] ? $own[0]{epoch} : ($prev ? $prev->{epoch} : undef);
    my @foreign = grep {
        my $s = $_->{fm}{session_id} // '';
        $s ne $sid && !$chain_sids{$s} && (!defined $since || ($_->{epoch} // 0) > $since)
            && !($base && $_->{path} eq $base->{path})
    } @$docs;
    my $nf_max = ($kind // '') eq 'foreign' ? 1 : 2;
    my @foreign_all = map {
        { path => _rel($ctx, $_->{path}), date => $_->{fm}{date}, sid8 => skills::ctx::sid8($_->{fm}{session_id}),
          inflight_line => _inflight_line($_) }
    } @foreign;
    my @newer_foreign = @foreign_all[0 .. ($#foreign_all < $nf_max ? $#foreign_all : $nf_max)];

    # Ownership: foreign commits since the chain's last git_commit, live peers
    # from the per-process records, the pin lock.
    my %ownership = (live_peers => [], foreign_commits => undef, pin_lock => _pin_lock($ctx, $sid));
    if ($g->{in_git}) {
        $ownership{live_peers} = [ map { { sid8 => $_->{sid8}, pid => $_->{pid} } }
                                   @{ skills::ctx::live_peers($ctx, $g->{worktree}, $sid) } ];
        if ($prev && $prev->{fm}{git_commit}) {
            $ownership{foreign_commits} = _foreign_commits($ctx, $g, $prev, [ @own_chain ], $id);
        }
    }
    if ($repin) { $ownership{repin} = $repin }

    # This session's own GSD line, GSD re-entry line and Active driver line (owner 2026-10-26
    # 21:37: from its transcript, never the worktree's .planning alone): {line, reentry, driver,
    # workstream, state}.
    my $gs = skills::core::gsd(sid => $sid, cwd => $cwd, worktree => $g->{worktree});
    my $gsd = $gs ? { map { defined $gs->{$_} ? ($_ => $gs->{$_}) : () } qw(line reentry driver workstream state) } : undef;
    $gsd->{line} //= $gs->{lines}[0] if $gsd && !defined $gsd->{driver};

    my ($queued_line, $queue_lane, $queue) = _queue($ctx, $sid);
    my $inflight = _inflight($ctx, $sid, $g);
    my ($tmp, $tmp_unread) = _tmp_candidates($ctx, $sid);

    my %config;
    for my $k (qw(handoff_root disposable_root disposable_keep_days evidence_quota_mb queue_cmd)) {
        my $src = exists $ctx->{flags}{$k} ? 'flag' : ($ctx->{settings}{_source}{$k} // 'resolved');
        my %c = (value => $ctx->{settings}{$k}, source => $src);
        $c{note} = $ctx->{notes}{$k} if $ctx->{notes}{$k};
        $config{$k} = \%c;
    }

    my %session = (id => $sid, sid8 => $id->{sid8}, actor => 'main', pid => (defined $id->{pid} ? 0 + $id->{pid} : undef),
                   previous_session_id => $lin->{previous_session_id}, lineage_reason => $lin->{lineage_reason} // 'none');
    $session{identity} = "degraded ($id->{degraded})" if $id->{degraded};

    # D-12: the handoff-root mode of this worktree; in repo mode, where publish exports.
    my $m = skills::core::mode($cwd);
    my %mode = (mode => $m->{mode}, reason => $m->{reason});
    my $export_target = ($m->{mode} eq 'repo' && defined $m->{root_rel})
        ? "$m->{root_rel}/" . File::Basename::basename($bucket) . "/$stem.md" : undef;

    my $wh_now = $g->{in_git} ? skills::gitfacts::work_hash($g->{worktree}) : undef;
    my %out = (
        checked_at        => skills::util::stamp($now),
        session           => \%session,
        repo              => $g->{repo},
        worktree          => $g->{worktree},
        branch            => $g->{branch},
        head              => $g->{head},
        porcelain         => ($g->{in_git} ? { first => $g->{porcelain}, count => $g->{dirty_count} } : undef),
        ahead             => $g->{ahead},
        behind            => $g->{behind},
        in_progress       => $g->{in_progress} // [],
        bucket            => \%bucket,
        stem              => $stem,
        stage             => $stage,
        nonce             => $nonce,
        previous_handoff  => ($base ? $base->{path} : undef),
        %carry,
        own_latest        => $own_latest,
        newer_foreign     => \@newer_foreign,
        ownership         => \%ownership,
        gsd               => $gsd,
        queued_line       => $queued_line,
        queue             => $queue,
        inflight_measured => $inflight,
        tmp_candidates    => $tmp,
        config            => \%config,
        reuse_window_min  => ((eval { settings::num_clamped("handoff_reuse_window_min") })[0] // $REUSE_WINDOW_MIN),    # SK-4
        mode              => \%mode,
        export_target     => $export_target,
    );
    my $pn = eval { plugver::line() };
    $out{plugin_notice} = $pn if defined $pn;
    if ($ht) {
        $out{handoff_turn} = { ht => $ht->{ht}, max_calls => $ht->{max_calls} };
        $out{resumed} = \1 if $resumed;
    }

    my %stage_settings = (
        v => 1, session_id => $sid, sid8 => $id->{sid8}, actor => 'main', nonce => $nonce, stem => $stem,
        date => skills::util::iso_local($now), checked_at => $out{checked_at},
        bucket => $bucket, bucket_rel => _rel($ctx, $bucket), bucket_source => $bucket{source},
        repo => $g->{repo}, worktree => $g->{worktree}, branch => $g->{branch}, head => $g->{head_full},
        work_hash => $wh_now, cwd => $cwd,
        previous_session_id => $lin->{previous_session_id}, lineage_reason => $lin->{lineage_reason} // 'none',
        previous_handoff => $out{previous_handoff}, previous_kind => $carry{previous_kind},
        previous_sid8 => $carry{previous_sid8}, previous_stamp => $carry{previous_stamp},
        own_previous_handoff => $carry{own_previous_handoff}, queue_lane => $queue_lane, queue_mode => $queue->{mode},
        handoff_ht => ($ht ? $ht->{ht} : undef), slug => $topic,
        mode => $m->{mode}, mode_reason => $m->{reason},
        gsd_state => ($gs && defined $gs->{state} && -f $gs->{state} ? $gs->{state} : undef),
        identity_degraded => $id->{degraded},
        # T-TEXT E6: the Acuity floor code measured (publish's acuity advisory reads it): a
        # merge, rebase, cherry-pick or revert in progress -> unstable; a measured in-flight
        # row -> watch; else stable.
        acuity_floor => (@{ $g->{in_progress} || [] } ? 'unstable' : @{ $inflight->{tasks} || [] } ? 'watch' : 'stable'),
        settings => { map { $_ => $ctx->{settings}{$_} } grep { !/\A_/ } keys %{ $ctx->{settings} } },
    );
    if (!$resumed) {
        skills::util::write_excl("$stage/settings.json", skills::util::json_encode(\%stage_settings) . "\n", 0600)
            or die "stage settings exist\n";
    } else {
        # CR-F10: the stage keeps its first settings.json; the checked_at printed now is
        # one more helper-printed time, so the publish lint accepts it (stamps.log, as
        # `stamp` writes it).
        skills::util::append_line("$stage/stamps.log", skills::util::iso_local($now) . "\t$out{checked_at}\n");
    }

    # U-04: the printed store paths, relative to store_root (the stage settings above keep
    # them whole: publish writes them into the frontmatter). The whole reply, with every
    # newer_foreign entry, goes to the stage before the fit can shorten any list, one entry a
    # line; the paths.jsonl rows begin did not read are counted in both.
    my %unread = $tmp_unread ? (tmp_candidates => $tmp_unread) : ();
    $out{store_root} = $ctx->{root};
    $out{bucket} = { %bucket, path => _rel($ctx, $bucket{path}) };
    $out{$_} = _rel($ctx, $out{$_}) for qw(previous_handoff own_previous_handoff);
    $out{own_latest} = { %$own_latest, path => _rel($ctx, $own_latest->{path}) } if $own_latest;
    $out{inflight_measured} = { %$inflight, sidecar => _rel($ctx, $inflight->{sidecar}) };
    skills::util::write_replace("$stage/$FULL_NAME", _json_lines({ %out, newer_foreign => \@foreign_all, (%unread ? (unread => \%unread) : ()) }) . "\n", 0600);

    # The reply's own caps: the first $INFLIGHT_SHOW tasks and $TMP_SHOW candidates; _fit
    # counts the rest against every entry begin found.
    my %found = (newer_foreign => scalar @foreign_all, inflight_measured => scalar @{ $inflight->{tasks} },
                 tmp_candidates => scalar @$tmp);
    $out{inflight_measured}{tasks} = _first($inflight->{tasks}, $INFLIGHT_SHOW);
    $out{tmp_candidates} = _first($tmp, $TMP_SHOW);
    skills::cli::say(_fit(\%out, \%found, _rel($ctx, "$stage/$FULL_NAME"), \%unread));
    return 0;
}

# The first n entries of a list, as a new list.
sub _first {
    my ($l, $n) = @_;
    return [ @$l[0 .. ($#$l < $n - 1 ? $#$l : $n - 1)] ];
}

# Newest frontmatter date first, file name as the tiebreak (a named sub: run() has a
# lexical $b).
sub _newest_first { return ($b->{epoch} // 0) <=> ($a->{epoch} // 0) || $b->{path} cmp $a->{path} }

# The settings.json of a stage that begin made, or undef.
sub _stage_meta {
    my ($stage) = @_;
    return undef unless defined $stage && -d $stage;
    my $d = eval { skills::util::json_decode(skills::util::read_file("$stage/settings.json", 262144)) };
    return (ref $d eq 'HASH' && $d->{nonce} && $d->{stem} && $d->{bucket}) ? $d : undef;
}

# A document's frontmatter date as a stamp (RV-24), or its raw date.
sub _doc_stamp {
    my ($d) = @_;
    return defined $d->{epoch} ? skills::util::stamp($d->{epoch}) : $d->{fm}{date};
}

# next_ids(docs) -> {U, D, X}: the highest id of each prefix over the documents plus 1,
# so the model never does id arithmetic (small-rulings §2.1).
sub next_ids {
    my (@docs) = @_;
    my %max = (U => 0, D => 0, X => 0);
    for my $d (@docs) {
        my $t = $d->{body} // $d->{text} // '';
        while ($t =~ /(?<![A-Za-z0-9])([UDX])-([0-9]{1,6})(?![0-9])/g) { $max{$1} = $2 if $2 > $max{$1} }
    }
    return { map { $_ => $max{$_} + 1 } keys %max };
}

# A store path relative to the store root; a path outside it (a bucket pinned under another
# root) stays whole, and undef stays undef.
sub _rel {
    my ($ctx, $p) = @_;
    return $p unless defined $p;
    my $r = $ctx->{root};
    return $p =~ s/\A\Q$r\E\///r;
}

# Another live session pinned to this bucket holds it (RV-28 ownership check).
sub _bucket_holder {
    my ($ctx, $bucket, $sid) = @_;
    my %live = map { $_->{session_id} => $_ } @{ skills::ctx::live_peers($ctx, undef, $sid) };
    my %seen;
    # STATE-ROOT: pins in both read roots (pin_read takes the store root's first)
    for my $f (map { skills::util::list_dir("$_/.sessions") } skills::ctx::read_roots($ctx)) {
        next unless $f =~ /\A(.+)\.json\z/ && $f !~ /\.lineage\.json\z/;
        my $other = $1;
        next if $other eq $sid || !$live{$other} || $seen{$other}++;
        my $pin = skills::ctx::pin_read($ctx, $other) or next;
        # (a bucket_path under an old default root that is gone reads as its copy under the new root)
        my $bp = skills::ctx::follow($ctx, $pin->{bucket_path} // ($pin->{bucket} ? "$ctx->{root}/$pin->{bucket}" : ''));
        # a legacy pin names its bucket under the legacy root: its relative name counts too
        return skills::ctx::sid8($other) if $bp eq $bucket || (defined $pin->{bucket} && !ref $pin->{bucket} && "$ctx->{root}/$pin->{bucket}" eq $bucket);
    }
    return undef;
}

# _pin_lock(ctx, sid) -> held | stale | free. The lock record (lock::with) keeps the
# holder's start time as `pid_lstart` (PF-9: reading `lstart` made every holder stale).
sub _pin_lock {
    my ($ctx, $sid) = @_;
    my $l = skills::ctx::pin_path($ctx, $sid) . '.lock';
    return 'free' unless -e $l;
    my $d = eval { skills::util::json_decode(skills::util::read_file($l, 4096)) };
    return 'free' unless ref $d eq 'HASH' && $d->{pid};
    return skills::ctx::pid_matches($d->{pid}, $d->{pid_lstart}) ? 'held' : 'stale';
}

sub _inflight_line {
    my ($d) = @_;
    my $lit;
    eval {
        require skills::spec;
        for my $h (@{ skills::spec::sections_main() }) {
            if ($h->{name} =~ /\AIn flight/) { $lit = $h->{literal}; last }
        }
        1;
    };
    return undef unless $lit;
    return skills::store::heading_line($d->{text}, $lit);
}

# D-21: a commit is ours when the chain names its hash or it falls in a
# range between two git_commit values recorded by the chain; else foreign.
sub _foreign_commits {
    my ($ctx, $g, $prev, $chain_docs, $id) = @_;
    my $cs = skills::gitfacts::commits_since($g->{worktree}, $prev->{fm}{git_commit});
    return { measured => \0 } unless $cs;
    my $named = join "\n", map { $_->{text} } @$chain_docs;
    my @foreign = grep {
        my $c = $_;
        !(index($named, substr($c->{hash}, 0, 7)) >= 0)
    } @$cs;
    return { count => scalar @foreign, since => substr($prev->{fm}{git_commit}, 0, 12),
             hashes => [ map { $_->{short} } @foreign[0 .. ($#foreign < 4 ? $#foreign : 4)] ] };
}

# Queue lane (OD-21, TPL §4.6; Q-ADAPTER QA-1, QA-B2): queue::lane is the one list parser.
# Returns (queued_line, lane, {mode, why}): with queue_cmd empty, mode off and no exec; a
# reply that breaks the contract gives degraded (<why>) and neither a Queued: line nor a lane.
sub _queue {
    my ($ctx, $sid) = @_;
    my $l = skills::core::queue_lane($sid, $ctx->{settings}{queue_cmd}, 5000);
    my $m = skills::core::queue_mode($l);
    return (undef, undef, $m) unless ($l->{status} // '') eq 'ok';
    my $lane = defined $l->{lane} && $l->{lane} =~ $LANE_RE ? $l->{lane} : undef;
    return ($l->{queued_line}, $lane, $m);
}

# Last background sidecar slot of this session (MOD §7 ring): the highest seq, never the
# newest mtime (DP-13; sidecar::newest). Every task, for begin-full.json; `gitignored` is
# measured (one git call each) only for the $INFLIGHT_SHOW the reply shows, "unmeasured" after
# them in a git worktree (null stays "not measured: no git").
sub _inflight {
    my ($ctx, $sid, $g) = @_;
    my ($d, $path) = skills::core::sidecar_newest("$ctx->{watch}/$sid");
    return { sidecar => undef, tasks => [] } unless $d && $path;
    my @tasks;
    for my $t (@{ sidecar_tasks($d) }) {
        my %r = (id => $t->{id}, kind => $t->{kind}, status => $t->{status});
        if (defined $t->{output}) {
            $r{output} = $t->{output};
            $r{exists} = -e $t->{output} ? \1 : \0;
            if ($g->{in_git} && @tasks >= $INFLIGHT_SHOW) {
                $r{gitignored} = 'unmeasured';
            } else {
                my $ig = $g->{in_git} ? skills::gitfacts::check_ignore($g->{worktree}, $t->{output}) : undef;
                $r{gitignored} = defined $ig ? ($ig ? \1 : \0) : undef;
            }
        }
        push @tasks, \%r;
    }
    return { sidecar => $path, ts => $d->{ts}, tasks => \@tasks };
}

# Normalise a sidecar slot → [{id, kind, status, output}] (shape assumed).
sub sidecar_tasks {
    my ($d) = @_;
    return [] unless ref $d eq 'HASH';
    my @out;
    for my $key (qw(tasks background_tasks crons session_crons)) {
        my $l = $d->{$key};
        next unless ref $l eq 'ARRAY';
        for my $t (@$l) {
            next unless ref $t eq 'HASH';
            push @out, {
                id     => $t->{id} // $t->{task_id} // $t->{runtime_id},
                kind   => $t->{kind} // $t->{type} // ($key =~ /cron/ ? 'cron' : 'shell'),
                status => $t->{status},
                output => $t->{output} // $t->{output_path} // $t->{output_file},
            };
        }
    }
    return \@out;
}

# Ephemeral paths the mod recorded from this session's tool calls (MOD §10), newest first:
# every distinct path, for begin-full.json. paths.jsonl only grows, its newest rows last: a
# file over $PATHS_READ_MAX is read from its last $PATHS_READ_MAX bytes (from the first whole
# row), and the older rows are counted, not read -> (paths, rows not read).
# STORE_TEST_PATHS_MAX sets the read size in test mode.
sub _tmp_candidates {
    my ($ctx, $sid) = @_;
    my $f = "$ctx->{watch}/$sid/paths.jsonl";
    my $max = $PATHS_READ_MAX;
    $max = 0 + $ENV{STORE_TEST_PATHS_MAX}
        if skills::util::test_mode() && ($ENV{STORE_TEST_PATHS_MAX} // '') =~ /\A[1-9][0-9]{0,9}\z/;
    my $size = -s $f;
    open(my $fh, '<:raw', $f) or return ([], 0);
    my ($t, $unread) = ('', 0);
    if (defined $size && $size > $max) {
        seek($fh, $size - $max, 0);
        my $part = <$fh>;    # the row the cut falls in, or the one it starts
        my $start = tell($fh);
        seek($fh, 0, 0);
        for (my $left = $start; $left > 0;) {
            my $got = read($fh, my $buf, $left < 1048576 ? $left : 1048576) or last;
            $unread += ($buf =~ tr/\n//);
            $left -= $got;
        }
        read($fh, $t, $max);
    } else {
        local $/;
        $t = <$fh> // '';
    }
    close $fh;
    my (%seen, @out);
    for my $l (reverse split /\n/, $t) {
        my $d = eval { skills::util::json_decode($l) } or next;
        my $p = ref $d eq 'HASH' ? ($d->{path} // $d->{p}) : undef;
        next unless defined $p && !ref $p;
        # a shell assignment or a wait spec the path was cut with (`F=/tmp/x`, `exit:/tmp/x`)
        $p = $1 if $p =~ m{\A[A-Za-z_][A-Za-z0-9_-]*[=:](/.*)\z}s;
        next if $seen{$p}++;
        my @st = stat $p;
        next if !@st && junk_path($p);
        push @out, { path => $p, exists => (@st ? \1 : \0), bytes => (@st ? $st[7] : undef) };
    }
    return (\@out, $unread);
}

# junk_path(path) -> 1 when a recorded path that names no file is a piece of a command, not a
# file a handoff could keep or dispose of (0.1.3 small fixes; begin calls it only for a path that
# does not exist, so a real file of any name stays): not absolute (`$S/tasks/x.output`,
# `F=$S/...`: read against no known folder), an unexpanded shell or template variable (`$S`,
# `${l.k}`, `$$`), a glob or brace pattern (`*`, `[`, `{`), a backslash (an escaped newline
# `\n` from a script's text), or a `...` part (an elided path, `/var/folders/.../T`).
sub junk_path {
    my ($p) = @_;
    return 1 unless defined $p && $p =~ m{\A/};
    return 1 if $p =~ /\$(?:[A-Za-z_{(\$]|\z)/;
    return 1 if $p =~ /[*\[\]{}\\]/;
    return 1 if $p =~ m{(?:\A|/)\.\.\.(?:/|\z)};
    return 0;
}

# begin-full.json's text: JSON with every object key and every list entry on its own line
# (an entry itself on one line), so a long list can be Read in pages.
sub _json_lines {
    my ($v, $ind) = @_;
    $ind //= '';
    my $in = "$ind ";
    if (ref $v eq 'HASH' && %$v) {
        return "{\n" . join(",\n", map { $in . skills::util::_jstr($_) . ':' . _json_lines($v->{$_}, $in) } sort keys %$v) . "\n$ind}";
    }
    if (ref $v eq 'ARRAY' && @$v) {
        return "[\n" . join(",\n", map { $in . skills::util::json_encode($_) } @$v) . "\n$ind]";
    }
    return skills::util::json_encode($v);
}

# Encode within 3 KB (U-04). What carries no entry goes first: the config source labels, then
# the two root values in config (whole paths; the handoff root is store_root again). Then
# lists are shortened in this order: the tails of tmp_candidates, porcelain.first and
# inflight_measured.tasks, gsd's workstream and state fields (its GSD, re-entry and Active
# driver lines stay), the rest of tmp_candidates and porcelain.first, and last
# newer_foreign, down to one entry (the handoff list the Ownership record rests on) and only
# when that brings the reply within 3 KB: an entry is never given up for nothing. Past every
# cut the reply stays over 3 KB. The cuts are greedy, so a later, larger cut can leave room:
# once within 3 KB, each cut is put back, the last first, while the reply stays within 3 KB
# (a list whose entry does not fit gets none of its earlier ones back). Nothing goes
# silently: `trimmed.cut` counts, under the reply key, the entries the reply leaves out,
# against every entry begin found ($found: a key's count when it is above the list's
# length; newer_foreign's cap of 2 or 3 and the in-flight and tmp caps cut alone), config and
# gsd: the fields dropped; `trimmed.all` names the file in the stage that holds them all;
# `trimmed.unread` ($unread) counts what begin did not read, so neither file has it. The
# counts are part of the encoded size.
sub _fit {
    my ($out, $found, $all, $unread) = @_;
    my %unread = map { ($unread->{$_} // 0) > 0 ? ($_ => $unread->{$_}) : () } keys %{ $unread || {} };
    my %list = (
        newer_foreign             => sub { $out->{newer_foreign} },
        tmp_candidates            => sub { $out->{tmp_candidates} },
        porcelain                 => sub { $out->{porcelain} ? $out->{porcelain}{first} : undef },
        inflight_measured         => sub { $out->{inflight_measured}{tasks} },
    );
    my $n = sub { my $l = $_[0]->(); return ref $l eq 'ARRAY' ? scalar @$l : 0 };
    my %total = map { $_ => $n->($list{$_}) } keys %list;
    for my $k (keys %{ $found || {} }) {
        $total{$k} = $found->{$k} if exists $total{$k} && ($found->{$k} // 0) > $total{$k};
    }
    my ($config_cut, $gsd_cut) = (0, 0);
    my $encode = sub {
        my %cut = map { my $c = $total{$_} - $n->($list{$_}); $c > 0 ? ($_ => $c) : () } keys %list;
        $cut{config} = $config_cut if $config_cut;
        $cut{gsd} = $gsd_cut if $gsd_cut;
        my %t = ((%cut ? (cut => \%cut) : ()), (%unread ? (unread => \%unread) : ()));
        if (%t) { $out->{trimmed} = { %t, all => $all } } else { delete $out->{trimmed} }
        return skills::util::json_encode($out);
    };
    # Each cut leaves [group, put back, cut again] for the put-back pass.
    my @done;
    my $pop = sub {
        my ($group, $l, $floor) = @_;
        return 0 unless ref $l eq 'ARRAY' && @$l > $floor;
        my $e = pop @$l;
        push @done, [ $group, sub { push @$l, $e }, sub { pop @$l } ];
        1;
    };
    my $drop = sub {
        my ($field) = @_;
        my $did = 0;
        for my $k (sort keys %{ $out->{config} || {} }) {
            my $c = $out->{config}{$k};
            next unless ref $c eq 'HASH' && exists $c->{$field};
            next if $field eq 'value' && $k ne 'handoff_root' && $k ne 'disposable_root';
            my $v = delete $c->{$field};
            $config_cut++;
            $did = 1;
            push @done, [ "config.$k.$field", sub { $c->{$field} = $v; $config_cut-- }, sub { delete $c->{$field}; $config_cut++ } ];
        }
        $did;
    };
    # gsd is this session's {line, reentry, driver, workstream, state}: workstream and state go
    # together (the GSD, re-entry and Active driver lines name them), counted as fields, as config.
    my $gsd_drop = sub {
        my $g = $out->{gsd};
        return 0 unless ref $g eq 'HASH';
        my @k = grep { exists $g->{$_} } qw(workstream state);
        return 0 unless @k;
        my %v = map { ($_ => delete $g->{$_}) } @k;
        $gsd_cut += @k;
        push @done, [ 'gsd', sub { @$g{ keys %v } = values %v; $gsd_cut -= @k }, sub { delete @$g{@k}; $gsd_cut += @k } ];
        1;
    };
    my $porc = sub { $out->{porcelain} ? $out->{porcelain}{first} : undef };
    my @trim = (
        sub { $drop->('source') },
        sub { $drop->('value') },
        sub { $pop->('tmp_candidates', $out->{tmp_candidates}, 3) },
        sub { $pop->('porcelain', $porc->(), 5) },
        sub { $pop->('inflight_measured', $out->{inflight_measured}{tasks}, 3) },
        sub { $gsd_drop->() },
        sub { $pop->('tmp_candidates', $out->{tmp_candidates}, 0) },
        sub { $pop->('porcelain', $porc->(), 0) },
        sub {
            my $l = $out->{newer_foreign};
            return 0 unless @$l > 1;
            my @had = @$l;
            splice(@$l, 1);
            my $fits = skills::util::blen($encode->()) <= $MAX_BYTES;
            @$l = @had;
            return $fits ? $pop->('newer_foreign', $l, 1) : 0;
        },
    );
    my $j = $encode->();
    for my $t (@trim) {
        while (skills::util::blen($j) > $MAX_BYTES && $t->()) { $j = $encode->() }
        last if skills::util::blen($j) <= $MAX_BYTES;
    }
    # The put-back pass: the last cut first, while the reply stays within 3 KB.
    if (skills::util::blen($j) <= $MAX_BYTES) {
        my %stuck;
        for my $d (reverse @done) {
            my ($group, $put, $recut) = @$d;
            next if $stuck{$group};
            $put->();
            next if skills::util::blen($encode->()) <= $MAX_BYTES;
            $recut->();
            $stuck{$group} = 1;
        }
    }
    return $encode->();
}

1;

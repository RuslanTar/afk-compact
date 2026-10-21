package skills::begin;
# lib/skills/begin.pm: `begin` (HDN §6; BUILD-PLAN §3.1 row; D-14, RV-18,
# RV-19, RV-26, RV-28, OD-16). Prints one JSON object of at most 3 KB and
# creates the stage <bucket>/.staging/<sid8>-<nonce>/ (0700) with settings.json.
use strict;
use warnings;
use Cwd ();
use File::Basename ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::gitfacts;
use skills::store;

# The HDN §6 keys, plus reuse_window_min (D-14). Exactly these are printed.
our @KEYS = qw(checked_at session repo worktree branch head porcelain ahead behind in_progress
               bucket stem stage nonce previous_handoff own_latest newer_foreign ownership gsd
               queued_line inflight_measured tmp_candidates config reuse_window_min);
our $REUSE_WINDOW_MIN = 15;
our $MAX_BYTES = 3072;
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
    my $cwd = skills::util::abs_path($o->{cwd} // Cwd::getcwd());
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
    my $bucket = $bucket{path};

    # Stage <bucket>/.staging/<sid8>-<nonce>/
    my ($nonce, $stage);
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

    my $stem = skills::util::stem_time($now) . '_' . $id->{sid8} . '_' . ($topic // slug(File::Basename::basename($bucket)) // 'handoff');

    # Own chain (RV-19): same sid, or proven by lineage. Foreign files only go
    # to newer_foreign.
    my $docs = [ grep { skills::store::is_handoff($_) } @{ skills::store::docs_in($bucket) } ];
    my @own = grep { ($_->{fm}{session_id} // '') eq $sid } @$docs;
    my @pred = grep { $chain_sids{ $_->{fm}{session_id} // '' } } @$docs;
    my $prev = $own[0] // $pred[0];
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
    my $since = $own[0] ? $own[0]{epoch} : ($prev ? $prev->{epoch} : undef);
    my @foreign = grep {
        my $s = $_->{fm}{session_id} // '';
        $s ne $sid && !$chain_sids{$s} && (!defined $since || ($_->{epoch} // 0) > $since)
    } @$docs;
    my @newer_foreign = map {
        { path => $_->{path}, date => $_->{fm}{date}, sid8 => skills::ctx::sid8($_->{fm}{session_id}),
          inflight_line => _inflight_line($_) }
    } @foreign[0 .. ($#foreign < 2 ? $#foreign : 2)];

    # Ownership: foreign commits since the chain's last git_commit, live peers
    # from the per-process records, the pin lock.
    my %ownership = (live_peers => [], foreign_commits => undef, pin_lock => _pin_lock($ctx, $sid));
    if ($g->{in_git}) {
        $ownership{live_peers} = [ map { { sid8 => $_->{sid8}, pid => $_->{pid} } }
                                   @{ skills::ctx::live_peers($ctx, $g->{worktree}, $sid) } ];
        if ($prev && $prev->{fm}{git_commit}) {
            $ownership{foreign_commits} = _foreign_commits($ctx, $g, $prev, [ @own, @pred ], $id);
        }
    }
    if ($repin) { $ownership{repin} = $repin }

    my $gsd = $g->{in_git} ? skills::core::gsd($g->{worktree}) : undef;
    $gsd = [ @$gsd[0 .. ($#$gsd < 7 ? $#$gsd : 7)] ] if $gsd;

    my ($queued_line, $queue_lane) = _queue($ctx, $sid);
    my $inflight = _inflight($ctx, $sid, $g);
    my $tmp = _tmp_candidates($ctx, $sid);

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
        previous_handoff  => ($prev ? $prev->{path} : undef),
        own_latest        => $own_latest,
        newer_foreign     => \@newer_foreign,
        ownership         => \%ownership,
        gsd               => $gsd,
        queued_line       => $queued_line,
        inflight_measured => $inflight,
        tmp_candidates    => $tmp,
        config            => \%config,
        reuse_window_min  => $REUSE_WINDOW_MIN,
    );

    my %stage_settings = (
        v => 1, session_id => $sid, sid8 => $id->{sid8}, actor => 'main', nonce => $nonce, stem => $stem,
        date => skills::util::iso_local($now), checked_at => $out{checked_at},
        bucket => $bucket, bucket_rel => _rel($ctx, $bucket), bucket_source => $bucket{source},
        repo => $g->{repo}, worktree => $g->{worktree}, branch => $g->{branch}, head => $g->{head_full},
        work_hash => $wh_now, cwd => $cwd,
        previous_session_id => $lin->{previous_session_id}, lineage_reason => $lin->{lineage_reason} // 'none',
        previous_handoff => $out{previous_handoff}, queue_lane => $queue_lane,
        gsd_state => ($gsd && $g->{worktree} && -f "$g->{worktree}/.planning/STATE.md" ? "$g->{worktree}/.planning/STATE.md" : undef),
        identity_degraded => $id->{degraded},
        settings => { map { $_ => $ctx->{settings}{$_} } grep { !/\A_/ } keys %{ $ctx->{settings} } },
    );
    skills::util::write_excl("$stage/settings.json", skills::util::json_encode(\%stage_settings) . "\n", 0600)
        or die "stage settings exist\n";

    skills::cli::say(_fit(\%out));
    return 0;
}

sub _rel {
    my ($ctx, $p) = @_;
    my $r = $ctx->{root};
    return $p =~ s/\A\Q$r\E\///r;
}

# Another live session pinned to this bucket holds it (RV-28 ownership check).
sub _bucket_holder {
    my ($ctx, $bucket, $sid) = @_;
    my $dir = "$ctx->{root}/.sessions";
    my %live = map { $_->{session_id} => $_ } @{ skills::ctx::live_peers($ctx, undef, $sid) };
    for my $f (skills::util::list_dir($dir)) {
        next unless $f =~ /\A(.+)\.json\z/ && $f !~ /\.lineage\.json\z/;
        my $other = $1;
        next if $other eq $sid || !$live{$other};
        my $pin = skills::ctx::pin_read($ctx, $other) or next;
        my $bp = $pin->{bucket_path} // ($pin->{bucket} ? "$ctx->{root}/$pin->{bucket}" : '');
        return skills::ctx::sid8($other) if $bp eq $bucket;
    }
    return undef;
}

sub _pin_lock {
    my ($ctx, $sid) = @_;
    my $l = skills::ctx::pin_path($ctx, $sid) . '.lock';
    return 'free' unless -e $l;
    my $d = eval { skills::util::json_decode(skills::util::read_file($l, 4096)) };
    return 'free' unless ref $d eq 'HASH' && $d->{pid};
    return skills::ctx::pid_matches($d->{pid}, $d->{lstart}) ? 'held' : 'stale';
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

# Queue lane listing (OD-21, TPL §4.6): only with queue_cmd set.
sub _queue {
    my ($ctx, $sid) = @_;
    my $cmd = $ctx->{settings}{queue_cmd};
    return (undef, undef) if skills::util::unset_value($cmd);
    my $r = skills::core::queue_call([ $cmd, 'list', '--json', '--session', $sid ], 5000);
    return ('Queued: not measured (timeout)', undef) if $r->{timed_out};
    return (undef, undef) if $r->{rc} != 0;
    my $d = eval { skills::util::json_decode($r->{out}) };
    my $q = queue_listing($d) or return (undef, undef);
    my $lane = $q->{lane};
    return (undef, undef) unless defined $lane && $lane =~ $LANE_RE;
    my @ids = @{ $q->{open} };
    return (undef, undef) if $lane =~ /\Aauto:/ && !@ids;
    my $line = sprintf('Queued: %d open in %s (%s); answered only via the queue; never re-ask.',
        scalar @ids, $q->{label} // $lane, join(', ', @ids) || 'none');
    return ($line, $lane);
}

# Normalise a `list --json` answer → {lane, label, open => [ids]} (shape assumed).
sub queue_listing {
    my ($d) = @_;
    $d = $d->[0] if ref $d eq 'ARRAY' && ref $d->[0] eq 'HASH' && exists $d->[0]{lane};
    return undef unless ref $d eq 'HASH';
    my $lane = $d->{lane} // $d->{lane_id} // $d->{id};
    $lane = $lane->{id} if ref $lane eq 'HASH';
    my $items = $d->{open} // $d->{pending} // $d->{items} // $d->{questions} // [];
    $items = [] unless ref $items eq 'ARRAY';
    my @ids = map { ref $_ eq 'HASH' ? ($_->{id} // ()) : $_ } @$items;
    @ids = grep { defined && !ref && /\A[A-Za-z0-9._:\/-]{1,64}\z/ } @ids;
    return { lane => $lane, label => (defined $d->{label} && !ref $d->{label} ? $d->{label} : undef), open => \@ids };
}

# Last background sidecar slot of this session (MOD §7 ring).
sub _inflight {
    my ($ctx, $sid, $g) = @_;
    my $dir = "$ctx->{watch}/$sid/bg";
    my @slots = grep { /\Aslot-\d+\.json\z/ } skills::util::list_dir($dir);
    return { sidecar => undef, tasks => [] } unless @slots;
    my ($newest) = sort { (stat "$dir/$b")[9] <=> (stat "$dir/$a")[9] || $b cmp $a } @slots;
    my $d = eval { skills::util::json_decode(skills::util::read_file("$dir/$newest", 262144)) } || {};
    my @tasks;
    for my $t (@{ sidecar_tasks($d) }) {
        my %r = (id => $t->{id}, kind => $t->{kind}, status => $t->{status});
        if (defined $t->{output}) {
            $r{output} = $t->{output};
            $r{exists} = -e $t->{output} ? \1 : \0;
            my $ig = $g->{in_git} ? skills::gitfacts::check_ignore($g->{worktree}, $t->{output}) : undef;
            $r{gitignored} = defined $ig ? ($ig ? \1 : \0) : undef;
        }
        push @tasks, \%r;
        last if @tasks >= 8;
    }
    return { sidecar => "$dir/$newest", ts => $d->{ts}, tasks => \@tasks };
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
                kind   => $t->{kind} // ($key =~ /cron/ ? 'cron' : 'shell'),
                status => $t->{status},
                output => $t->{output} // $t->{output_path} // $t->{output_file},
            };
        }
    }
    return \@out;
}

# Ephemeral paths the mod recorded from this session's tool calls (MOD §10).
sub _tmp_candidates {
    my ($ctx, $sid) = @_;
    my $t = skills::util::read_file("$ctx->{watch}/$sid/paths.jsonl", 1024 * 1024);
    return [] unless defined $t;
    my (%seen, @out);
    for my $l (reverse split /\n/, $t) {
        my $d = eval { skills::util::json_decode($l) } or next;
        my $p = ref $d eq 'HASH' ? ($d->{path} // $d->{p}) : undef;
        next unless defined $p && !ref $p && !$seen{$p}++;
        my @st = stat $p;
        push @out, { path => $p, exists => (@st ? \1 : \0), bytes => (@st ? $st[7] : undef) };
        last if @out >= 20;
    }
    return \@out;
}

# Encode within 3 KB: trim the longest lists first, then note the cut.
sub _fit {
    my ($out) = @_;
    my $j = skills::util::json_encode($out);
    my @trim = (
        sub { my $l = $out->{tmp_candidates}; return 0 unless @$l > 3; pop @$l; 1 },
        sub { my $p = $out->{porcelain}; return 0 unless $p && @{ $p->{first} } > 5; pop @{ $p->{first} }; 1 },
        sub { my $l = $out->{inflight_measured}{tasks}; return 0 unless $l && @$l > 3; pop @$l; 1 },
        sub { my $l = $out->{newer_foreign}; return 0 unless @$l > 1; pop @$l; 1 },
        sub { my $g = $out->{gsd}; return 0 unless $g && @$g > 3; pop @$g; 1 },
        sub { my $l = $out->{tmp_candidates}; return 0 unless @$l; pop @$l; 1 },
        sub { my $p = $out->{porcelain}; return 0 unless $p && @{ $p->{first} }; pop @{ $p->{first} }; 1 },
        sub { my $c = $out->{config}; my $did = 0; for (values %$c) { $did = 1 if delete $_->{source} } $did },
    );
    for my $t (@trim) {
        while (length($j) > $MAX_BYTES && $t->()) { $j = skills::util::json_encode($out) }
        last if length($j) <= $MAX_BYTES;
    }
    return $j;
}

1;

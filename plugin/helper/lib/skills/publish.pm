package skills::publish;
# lib/skills/publish.pm: `publish --stage DIR --slug S --status …` (HDN §6,
# TPL §3, §5, §6, §7; D-1, D-13). Lint and secret scan, then in this order:
# file the stage into evidence/<stem>/ (recipes gain sha256 and
# origin_session_id), MANIFEST.tsv, the handoff by exclusive create, read
# back, pin under lock, one receipt and one handoff_publish row.
# 2026-10-21 rulings: the lint also sees the own chain's file when the carry base is
# foreign (small-rulings §2.4) and, in repo mode, the export text (private-path); the
# frontmatter keys and their order are the spec's frontmatter_keys_handoff (with
# previous_kind and own_previous_handoff, RV-19); a stage bound to a plugin handoff turn
# publishes once (`<ht>.published` before the handoff file, else REFUSED: handoff-exists
# <path>, D-18 B8); shell recipes of a recorded job carry `job:` and the recorded
# command (Dev-1 D2); in repo mode the handoff is then exported (D-12 §1.5.5,
# skills/export.pm) and one receipt line says what happened to the export.
use strict;
use warnings;
use File::Basename ();
use skills::util;
use skills::cli;
use skills::core;
use skills::ctx;
use skills::stage;
use skills::store;
use skills::spec;
use skills::lint;
use skills::gitfacts;
use skills::export;

my %STATUS = map { $_ => 1 } qw(in-progress blocked completed);
my $LANE_RE = qr/\A(?:lane|auto):[A-Za-z0-9._\/-]+\z/;
# Frontmatter keys and their order: the spec's frontmatter_keys_handoff (TPL §3); empty
# values are omitted. The list is read at publish time (fail closed: spec-missing).

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'stage=s', 'slug=s', 'status=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--status in-progress|blocked|completed') unless defined $o->{status} && $STATUS{ $o->{status} };
    die skills::cli::usage('--slug must be kebab-case') unless defined $o->{slug} && $o->{slug} =~ /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/;
    my ($dir, $s, $ctx) = skills::stage::open_stage($o->{stage});
    my $row = { kind => 'handoff', writer => 'handoff', bytes => 0, lint_rules => [], size_band => undef };

    if (-e "$dir/published") {
        _refuse($ctx, $row, 'already-published');
    }
    my $rr = skills::core::roots_check($ctx->{settings});
    _refuse($ctx, $row, $rr) if $rr;
    my $body = skills::util::read_file("$dir/body.md");
    _refuse($ctx, $row, 'no-draft') unless defined $body && $body =~ /\S/;
    _refuse($ctx, $row, 'spec-missing') unless skills::spec::available();
    my $need = eval { skills::spec::need(qw(frontmatter_keys_handoff frontmatter_keys_export time_re lint_ids carry.tag_re private_path_classes)); 1 };
    _refuse($ctx, $row, ($@ =~ s/\s+\z//r)) unless $need;
    my $ht = (defined $s->{handoff_ht} && skills::core::ht_valid($s->{handoff_ht})) ? $s->{handoff_ht} : undef;
    my $sid_dir = skills::core::sid_dir();
    if ($ht && defined $sid_dir) {
        my $done = skills::core::ht_record($sid_dir, $ht) && handoff_turn::published_of($sid_dir, $ht);
        _refuse($ctx, $row, "handoff-exists $done") if $done;
    }

    my %recipes;
    for my $f (skills::util::list_dir("$dir/restart")) {
        next unless $f =~ /\.md\z/ && -f "$dir/restart/$f";
        $recipes{$f} = skills::util::read_file("$dir/restart/$f") // '';
    }
    my %extra;
    for my $f ('ledger.md', 'inflight.md') {
        $extra{$f} = skills::util::read_file("$dir/$f") if -f "$dir/$f";
    }
    my ($prev_text, $own_text);
    if ($s->{previous_handoff} && -f $s->{previous_handoff}) {
        my $pd = skills::store::read_doc($s->{previous_handoff});
        $prev_text = $pd->{body} if $pd;
    }
    if (($s->{previous_kind} // '') eq 'foreign' && $s->{own_previous_handoff} && -f $s->{own_previous_handoff}) {
        my $od = skills::store::read_doc($s->{own_previous_handoff});
        $own_text = $od->{body} if $od;
    }
    # D-12: the mode of this worktree, decided again for this call; in repo mode the lint
    # sees the text the export would hold.
    my $m = skills::core::mode($s->{cwd} // $s->{worktree} // $s->{bucket});
    my $repo = $m->{mode} eq 'repo' && defined $m->{root_path};
    my $xplan = $repo ? skills::export::plan($m, "$s->{bucket}/$s->{stem}.md") : undef;
    my $jobs = _jobs($s);
    my $ev = skills::stage::evidence_rows($dir);
    my $res = eval { skills::lint::lint({
        body => $body, recipes => \%recipes, extra => \%extra, previous => $prev_text,
        previous_kind => $s->{previous_kind}, own_previous => $own_text,
        repo_mode => ($repo ? 1 : 0), export_text => ($repo ? skills::export::body($body, $m, $xplan) : undef),
        jobs => $jobs, times => skills::stage::printed_times($dir, $s), evidence => $ev, bucket => $s->{bucket},
        brand => $ctx->{brand},
    }) };
    if (!$res) { my $e = $@; _refuse($ctx, $row, $e =~ s/\s+\z//r) if $e =~ /\Aspec-missing /; die $e }
    $row->{bytes} = length $body;
    $row->{size_band} = _band(length $body);
    my @b = @{ $res->{blocking} };
    my @a = @{ $res->{advisory} };
    my %rules;
    $rules{ $_->[0] } = 1 for @b, @a;
    $row->{lint_rules} = [ sort keys %rules ];
    skills::cli::say("LINT $_->[0] $_->[1]") for @b;
    skills::cli::say("ADVISORY $_->[0] $_->[1]") for @a;
    if (@b) {
        $row->{result} = 'REFUSED:lint';
        $row->{blocking} = scalar @b;
        $ctx->log('handoff_publish', $row);
        die skills::cli::refuse(sprintf('lint (%d blocking); draft kept at %s/body.md', scalar @b, $dir));
    }

    # ---- file the stage into evidence/<stem>/
    my $now = skills::util::now();
    my $bucket = $s->{bucket};
    my $edir = "$bucket/evidence/$s->{stem}";
    my @manifest;
    for my $r (@$ev) {
        next if ($r->{status} // '') eq 'missing';
        push @manifest, {
            copy_path => $r->{copy}, origin => $r->{origin}, bytes => $r->{bytes}, sha256 => $r->{sha256},
            mtime => $r->{mtime}, copied_at => $r->{ts}, mode => ($r->{copy} ? '0600' : ''),
            scan => _scan($r), regen_cmd => '', meaning => ($r->{where} eq 'dispose' ? 'disposable' : ''),
        };
    }
    my %by_copy = map { ($_->{copy} // '') => $_ } grep { $_->{copy} } @$ev;
    my @stage_files;
    for my $f (sort keys %recipes) {
        my $t = $recipes{$f};
        my $script_sha = 'none';
        if ($t =~ /^\s*script:\s*(\S+)/m && $1 !~ /\Anone\z/i) {
            my $sp = $1;
            my $abs = $sp =~ m{\A/} ? $sp : "$bucket/$sp";
            $script_sha = $by_copy{$abs} ? $by_copy{$abs}{sha256} : (skills::util::sha256_file($abs) // 'none');
        }
        $t = _job_lines($t, $jobs);
        $t .= "\n" unless $t =~ /\n\z/;
        $t .= "sha256: $script_sha\norigin_session_id: $s->{session_id}\n";
        my ($item) = $f =~ /\A(.+)\.md\z/;
        push @stage_files, [ "restart/$f", $t, "restart recipe $item", "$dir/restart/$f" ];
    }
    for my $f (sort keys %extra) {
        push @stage_files, [ $f, $extra{$f}, ($f eq 'ledger.md' ? 'ledger' : 'in-flight overflow'), "$dir/$f" ];
    }
    if (@stage_files || grep { $_->{copy_path} && index($_->{copy_path}, "$edir/") == 0 } @manifest) {
        skills::util::mkdir_p($edir);
    }
    for my $sf (@stage_files) {
        my ($rel, $content, $meaning, $origin) = @$sf;
        my $dest = "$edir/$rel";
        skills::util::mkdir_p(File::Basename::dirname($dest));
        skills::util::write_excl($dest, $content, 0600) or die "exists: $dest\n";
        my $sha = skills::util::sha256_file($dest);
        push @manifest, { copy_path => $dest, origin => $origin, bytes => length($content), sha256 => $sha,
                          mtime => skills::util::iso_local((stat $dest)[9]), copied_at => skills::util::iso_local($now),
                          mode => '0600', scan => 'full', regen_cmd => '', meaning => $meaning };
    }
    if (@manifest) {
        skills::util::mkdir_p($edir);
        my $m = join("\t", skills::store::manifest_cols()) . "\n" . join('', map { skills::store::manifest_line($_) } @manifest);
        skills::util::write_excl("$edir/MANIFEST.tsv", $m, 0600) or die "exists: $edir/MANIFEST.tsv\n";
    }

    # ---- frontmatter, marker, sentinel; exclusive create; read back
    my $g = skills::gitfacts::facts($s->{cwd} // $s->{worktree} // $bucket);
    my $cp = skills::core::claude_pid();
    my %fm = (
        kind => 'handoff', writer => 'handoff', nonce => $s->{nonce}, date => skills::util::iso_local($now),
        session_id => $s->{session_id}, actor => 'main',
        previous_session_id => $s->{previous_session_id}, lineage_reason => $s->{lineage_reason},
        claude_pid => ($cp ? $cp->{pid} : undef), cc_version => _cc_version($ctx),
        repository => $s->{repo}, bucket => $s->{bucket_rel}, worktree => $g->{worktree} // $s->{worktree},
        branch => $g->{branch} // $s->{branch}, git_commit => $g->{head_full} // $s->{head},
        status => $o->{status},
        ticket => skills::gitfacts::ticket($g->{branch} // $s->{branch}) // skills::gitfacts::ticket(File::Basename::basename($bucket)),
        queue_lane => (defined $s->{queue_lane} && $s->{queue_lane} =~ $LANE_RE ? $s->{queue_lane} : undef),
        previous_handoff => $s->{previous_handoff}, gsd => $s->{gsd_state},
        previous_kind => $s->{previous_kind},
        own_previous_handoff => (($s->{previous_kind} // '') eq 'foreign' ? $s->{own_previous_handoff} : undef),
    );
    my $fm = "---\n" . join('', map { "$_: $fm{$_}\n" } grep { defined $fm{$_} && $fm{$_} ne '' }
                               @{ skills::spec::frontmatter_keys('handoff') }) . "---\n";
    my $brand = $ctx->{brand};
    my $marker = "\x{e2}\x{9f}\x{aa}$brand v1 n=$s->{nonce} s=manual\x{e2}\x{9f}\x{ab}";
    my $sentinel = "\x{e2}\x{9f}\x{aa}/$brand n=$s->{nonce}\x{e2}\x{9f}\x{ab}";
    my ($mre, $sre) = (skills::spec::marker_re(), skills::spec::sentinel_re());
    die "marker does not match the spec grammar\n" if ($mre && $marker !~ $mre) || ($sre && $sentinel !~ $sre);
    (my $btxt = $body) =~ s/\s+\z//;
    my ($path, $content);
    for (1 .. 5) {
        $path = skills::util::unique_path($bucket, $s->{stem}, '.md');
        (my $bb = $btxt) =~ s/\@self\@/$path/g;
        $content = $fm . $marker . "\n" . $bb . "\n" . $sentinel . "\n";
        if ($ht && defined $sid_dir) {
            # One handoff per plugin handoff turn: the claim comes first (D-18 B8).
            my ($ok, $have) = skills::core::ht_mark_published($sid_dir, $ht, $path);
            if (!$ok) { _refuse($ctx, $row, "handoff-exists $have") }
        }
        last if skills::util::write_excl($path, $content, 0600);
        die "handoff name taken after the handoff-turn claim: $path\n" if $ht;
        undef $path;
    }
    die "no free handoff name\n" unless $path;
    my $back = skills::util::read_file($path);
    my @tail = grep { /\S/ } split /\n/, ($back // '');
    die "read-back failed: $path\n" unless defined $back && skills::util::sha256_hex($back) eq skills::util::sha256_hex($content)
        && @tail && $tail[-1] eq $sentinel;
    skills::util::write_excl("$dir/published", "$path\n", 0600);

    # ---- pin under the TPL §6 lock
    my $wh = $g->{in_git} ? skills::gitfacts::work_hash($g->{worktree}) : undef;
    my ($ok, $err) = skills::ctx::pin_update($ctx, $s->{session_id}, sub {
        my ($pin) = @_;
        my %n = %$pin;
        $n{bucket} = $s->{bucket_rel};
        $n{bucket_path} = $bucket;
        $n{bucket_source} = $s->{bucket_source};
        $n{worktree} = $g->{worktree} // $s->{worktree};
        $n{lane} = $fm{queue_lane} if defined $fm{queue_lane} && $fm{queue_lane} =~ /\Alane:/;
        $n{last_handoff} = { path => $path, date => $fm{date}, head => $g->{head_full}, work_hash => $wh };
        return \%n;
    });
    if (!$ok) {
        skills::cli::say('ADVISORY pin-locked ' . skills::ctx::pin_path($ctx, $s->{session_id}));
        $row->{lint_rules} = [ sort(@{ $row->{lint_rules} }, 'pin-locked') ];
    }
    $row->{result} = 'wrote';
    $row->{bucket_source} = $s->{bucket_source};
    $row->{handoff_ht} = $ht if $ht;
    $ctx->log('handoff_publish', $row);
    skills::cli::say("Wrote handoff to: $path");

    # ---- D-12 export (repo mode only), after the private handoff is safe.
    if ($repo) {
        my %pfm = map { $_ => $fm{$_} } grep { defined $fm{$_} } keys %fm;
        my $x = skills::export::export_one(mode => $m, private => $path, fm => \%pfm, body => $btxt,
                                           marker => $marker, sentinel => $sentinel);
        $ctx->log('handoff_export', { result => $x->{result}, reason => $x->{reason}, bytes => $x->{bytes}, rules => $x->{rules} });
        if ($x->{result} eq 'exported' || $x->{result} eq 'exists') {
            skills::cli::say("Exported to repository: $x->{rel} (untracked; review and commit it yourself)");
        } else {
            my $why = $x->{reason} // 'unknown';
            $why .= ' ' . join(',', @{ $x->{rules} }) if $why =~ /\Asecret/ && @{ $x->{rules} };
            skills::cli::say("Export refused: $why");
        }
    } elsif (($m->{reason} // '') eq 'not-accepted') {
        my $mc = $m->{main_checkout} // $m->{toplevel} // 'this repository';
        $ctx->log('handoff_export', { result => 'not-exported', reason => 'not-accepted', bytes => 0, rules => [] });
        skills::cli::say("Not exported: repository asks for repo mode; accept it by adding $mc to repo_roots in /config");
    }
    return 0;
}

# Dev-1 job rows of this stage's session, newest per task: {task id => row}.
sub _jobs {
    my ($s) = @_;
    my $d = skills::core::sid_dir() // return {};
    my %j;
    for my $r (@{ skills::core::job_rows($d) }) {
        next unless ($r->{ev} // $r->{kind} // '') eq 'job' && defined $r->{task_id};
        $j{ $r->{task_id} } = $r;
    }
    return \%j;
}

# Dev-1 D2: a recipe for a task the plugin recorded gets `job: <id> · recorded` and the
# recorded command (a withheld one is named, never printed); one with a runtime id and
# no record gets `job: <id> · not recorded`. Hand-typed text is shown, never run.
sub _job_lines {
    my ($t, $jobs) = @_;
    my ($rid) = $t =~ /^\s*item:\s*B-\d+.*?runtime id\s+([A-Za-z0-9._:-]+)/m;
    return $t unless defined $rid && $t !~ /^\s*job:/m;
    my $job = $jobs->{$rid};
    if (!$job) {
        $t =~ s/^(\s*item:[^\n]*\n)/$1job: $rid · not recorded\n/m;
        return $t;
    }
    my $cmd = defined $job->{command} ? $job->{command}
            : '(withheld: ' . join(',', @{ ref $job->{command_withheld} eq 'ARRAY' ? $job->{command_withheld} : ['secret'] }) . ')';
    $cmd =~ s/[\r\n]+/ /g;
    if ($t =~ /^\s*command:/m) { $t =~ s/^(\s*)command:[^\n]*/$1command: $cmd/m }
    else { $t =~ s/^(\s*item:[^\n]*\n)/$1command: $cmd\n/m }
    $t =~ s/^(\s*item:[^\n]*\n)/$1job: $rid · recorded\n/m;
    return $t;
}

sub _refuse {
    my ($ctx, $row, $why) = @_;
    my $class = $why =~ s/\s.*//sr;
    $row->{result} = "REFUSED:$class";
    $ctx->log('handoff_publish', $row);
    die skills::cli::refuse($why);
}

sub _band {
    my ($n) = @_;
    return 'lt6k' if $n < 6 * 1024;
    return '6-15k' if $n <= 15 * 1024;
    return '15-20k' if $n <= 20 * 1024;
    return 'gt20k';
}

sub _scan {
    my ($r) = @_;
    my $st = $r->{status} // '';
    return 'withheld' if $st eq 'withheld';
    return 'ref-only' if $st eq 'ref-only';
    return 'redacted' if $st eq 'redacted';
    return $r->{scan} && $r->{scan} =~ /\A(full|excerpt)\z/ ? $r->{scan} : 'full';
}

# Last version the mod recorded (C1 mirror), if any.
sub _cc_version {
    my ($ctx) = @_;
    my $d = eval { skills::util::json_decode(skills::util::read_file("$ctx->{watch}/version.json", 65536)) };
    return undef unless ref $d eq 'HASH';
    my $v = $d->{lastVersion} // $d->{version};
    return (defined $v && !ref $v && $v =~ /\A[0-9A-Za-z.+-]{1,32}\z/) ? $v : undef;
}

1;

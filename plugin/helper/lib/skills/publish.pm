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
# <path>, D-18 B8; a claim whose file was never placed is filled by a retry of the same
# stage, CR-F9); shell recipes of a recorded job carry `job:` and the recorded
# command (Dev-1 D2); in repo mode the handoff is then exported (D-12 §1.5.5,
# skills/export.pm) and one receipt line says what happened to the export.
# 2026-10-23 (AP-4): the lint checks `## Approvals` (skills/approvals.pm) against the own
# chain's file and this session's transcript; the ids that passed go to frontmatter
# `approvals_checked`, and the row gains `approvals {lines, checked, unchecked}` and
# `approval_classes` (counts and class ids only).
# 0.1.2 (D-8): in a stage bound to a plugin handoff turn every own approval is context only
# (skills/approvals.pm): no approvals_checked and no line-hash record, so nothing carries; the
# frontmatter says `requested_by: plugin` (AC-4).
# 0.1.3 APPROVALS: an own approval line of `## Approvals` failing approval-quote or
# approval-plugin-turn moves to `## Open questions` as a re-ask instead of refusing (one ADVISORY
# line each; skills::approvals::move_lines); the row gains `approvals_moved` (a count).
use strict;
use warnings;
use utf8;
use File::Basename ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
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
use skills::approvals;

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
    # T-TEXT E7 (E-1 counters): every publish call on this stage counts, a refused one too, and
    # each row names the built template the skill read.
    $row->{attempt} = _attempt($dir);
    $row->{template_rev} = _template_rev();
    $row->{acuity_floor} = (defined $s->{acuity_floor} && $s->{acuity_floor} =~ /\A[a-z]+\z/) ? $s->{acuity_floor} : '-';

    if (-e "$dir/published") {
        _refuse($ctx, $row, 'already-published');
    }
    my $rr = skills::core::roots_check($ctx->{settings});
    _refuse($ctx, $row, $rr) if $rr;
    my $body = skills::util::read_text("$dir/body.md");
    _refuse($ctx, $row, 'no-draft') unless defined $body && $body =~ /\S/;
    _refuse($ctx, $row, 'spec-missing') unless skills::spec::available();
    my $need = eval { skills::spec::need(qw(frontmatter_keys_handoff frontmatter_keys_export time_re lint_ids carry.tag_re private_path_classes)); 1 };
    _refuse($ctx, $row, ($@ =~ s/\s+\z//r)) unless $need;
    my $ht = (defined $s->{handoff_ht} && skills::core::ht_valid($s->{handoff_ht})) ? $s->{handoff_ht} : undef;
    # DP-16: a publish inside a plugin handoff turn names its ht on every handoff_publish row,
    # so the watcher's A-18 matches the row to the turn exactly, not by time.
    $row->{ht} = $ht if $ht;
    my $sid_dir = skills::core::sid_dir();
    # CR-F9: a claim whose file was never placed (the earlier publish of this stage died
    # between the claim and the link) is fulfilled by this retry, at the claimed path only;
    # see _claimed_free. Any other claim refuses.
    my $claimed;
    if ($ht && defined $sid_dir) {
        my $done = skills::core::ht_record($sid_dir, $ht) && skills::core::ht_published_of($sid_dir, $ht);
        if ($done) {
            _refuse($ctx, $row, "handoff-exists $done") unless _claimed_free($done, $s);
            $claimed = $done;
        }
    }

    my %recipes;
    for my $f (skills::util::list_dir("$dir/restart")) {
        next unless $f =~ /\.md\z/ && -f "$dir/restart/$f";
        $recipes{$f} = skills::util::read_text("$dir/restart/$f") // '';
    }
    my %extra;
    for my $f ('ledger.md', 'inflight.md') {
        $extra{$f} = skills::util::read_text("$dir/$f") if -f "$dir/$f";
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
    # AP-4: the own chain's file (its approvals_checked ids carry) and this session's transcript.
    my $pk = $s->{previous_kind} // '';
    my $own_path = ($pk eq 'own' || $pk eq 'chain') ? $s->{previous_handoff} : $pk eq 'foreign' ? $s->{own_previous_handoff} : undef;
    # Only a file that is own by spec §4 lends its checked ids (REVIEW-NIGHT-3 R3-03: not a fork's
    # or bg-copy's base, owner xxxxxxxx-27 revised; not an export, an imported copy or a file
    # outside the store).
    my @achain = grep { defined } skills::approvals::chain_doc($own_path, $ctx, $s->{session_id});
    my $transcript = skills::approvals::transcript_path($ctx, $s->{session_id}, $s->{cwd}, $s->{worktree});
    my $times = skills::stage::printed_times($dir, $s);
    my $floor = [ skills::approvals::quote_floor($ctx, $s->{session_id}) ];
    my $lint = sub {
        my ($text) = @_;
        my $r = eval { skills::lint::lint({
            body => $text, recipes => \%recipes, extra => \%extra, previous => $prev_text,
            previous_kind => $s->{previous_kind}, own_previous => $own_text,
            repo_mode => ($repo ? 1 : 0), export_text => ($repo ? skills::export::body($text, $m, $xplan) : undef),
            jobs => $jobs, times => $times, evidence => $ev, bucket => $s->{bucket},
            brand => $ctx->{brand}, acuity_floor => ($row->{acuity_floor} eq '-' ? undef : $row->{acuity_floor}),
            queue_mode => $s->{queue_mode}, approval_chain => \@achain, transcript => $transcript, session_id => $s->{session_id},
            quote_floor => $floor,
            approval_context_only => (defined $ht ? 1 : 0),
        }) };
        if (!$r) { my $e = $@; _refuse($ctx, $row, $e =~ s/\s+\z//r) if $e =~ /\Aspec-missing /; die $e }
        return $r;
    };
    my $res = $lint->($body);
    # 0.1.3 APPROVALS: an own approval line of `## Approvals` that fails approval-quote or
    # approval-plugin-turn no longer refuses: it moves to `## Open questions` as a re-ask
    # (skills::approvals::move_lines) and one ADVISORY line per moved approval says so, with the
    # draft's line number and the rule in plain words. When nothing else blocks, the moved text is
    # linted again and published (its approvals, checks and hashes are the moved text's); when
    # something else blocks, publish refuses as before and the ADVISORY lines say what publish will
    # move once the rest passes.
    my ($mbody, $moved, $keep) = skills::approvals::move_lines($body, $res->{blocking});
    my %rules;
    if (@$moved) {
        $rules{ $_->{rule} } = 1 for @$moved;
        if (!@$keep) {
            $body = $mbody;
            $res = $lint->($body);
            $keep = $res->{blocking};
        }
        $row->{approvals_moved} = scalar @$moved;
    }
    $row->{bytes} = skills::util::blen($body);
    $row->{size_band} = _band($row->{bytes});
    my @b = @$keep;
    my @a = @{ $res->{advisory} };
    $rules{ $_->[0] } = 1 for @b, @a;
    $row->{lint_rules} = [ sort keys %rules ];
    $row->{acuity} = $res->{acuity} // '-';
    # AP-4: counts and outward class ids only, never a quote, action or target.
    my $ap = $res->{approvals} || {};
    # A plugin handoff turn (0.1.2 D-8): nothing in this file is listed as checked or hashed.
    $ap = { %$ap, checked => [], origins => {}, classes => [] } if defined $ht;
    if ($ap->{lines}) {
        $row->{approvals} = { lines => $ap->{lines}, checked => scalar(@{ $ap->{checked} || [] }), unchecked => $ap->{unchecked} // 0 };
        $row->{approvals}{context} = $ap->{context} if $ap->{context};
        $row->{approval_classes} = $ap->{classes} || [];
    }
    # T-TEXT E7: under the first line of each id in this run, its `  why: … · fix: …` line from
    # the spec's lint_texts (an id without one is a build failure, AT-TX-03; a spec without
    # lint_texts at all, older than T-TEXT E2, prints the first lines only).
    my $texts = skills::spec::lint_texts();
    my %told;
    my $why = sub {
        my ($id) = @_;
        return if !%$texts || $told{$id}++;
        my $t = $texts->{$id} or die "lint id $id has no lint_texts entry in the spec\n";
        skills::cli::say("  why: $t->{why} · fix: $t->{fix}");
    };
    for (@b) { skills::cli::say("LINT $_->[0] $_->[1]"); $why->($_->[0]) }
    for (@$moved) {
        skills::cli::say("ADVISORY $_->{rule} line $_->{line}: $_->{id} goes to Open questions as $_->{q}, a re-ask; $_->{why}");
        $why->($_->{rule});
    }
    for (@a) { skills::cli::say("ADVISORY $_->[0] $_->[1]"); $why->($_->[0]) }
    if (@b) {
        $row->{result} = 'REFUSED:lint';
        $row->{blocking} = scalar @b;
        $ctx->log('handoff_publish', $row);
        die skills::cli::refuse(sprintf('lint (%d blocking); draft kept at %s/body.md', scalar @b, $dir));
    }

    # ---- file the stage into evidence/<stem>/
    my $now = skills::util::now();
    my $bucket = $s->{bucket};
    # STATE-ROOT: a stage begun before 0.1.2 publishes into its bucket under the new root (open_stage)
    skills::util::mkdir_p($bucket) unless -d $bucket;
    my $edir = "$bucket/evidence/$s->{stem}";
    my @manifest;
    for my $r (@$ev) {
        next if ($r->{status} // '') eq 'missing';
        push @manifest, {
            copy_path => $r->{copy}, origin => $r->{origin}, bytes => $r->{bytes}, sha256 => $r->{sha256},
            mtime => $r->{mtime}, copied_at => $r->{ts}, mode => ($r->{copy} ? '0600' : ''),
            scan => _scan($r), regen_cmd => '',
            meaning => ($r->{meaning} // ($r->{where} eq 'dispose' ? 'disposable' : '')),
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
        push @manifest, { copy_path => $dest, origin => $origin, bytes => skills::util::blen($content), sha256 => $sha,
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
        approvals_checked => (@{ $ap->{checked} || [] } ? join(', ', @{ $ap->{checked} }) : undef),
        # 0.1.2 AC-4: the plugin asked for this handoff (a stage bound to a handoff turn), so
        # `measure` names that reason and none of its approvals carries.
        requested_by => ($ht ? 'plugin' : undef),
    );
    my $fm = "---\n" . join('', map { "$_: $fm{$_}\n" } grep { defined $fm{$_} && $fm{$_} ne '' }
                               @{ skills::spec::frontmatter_keys('handoff') }) . "---\n";
    my $brand = $ctx->{brand};
    my $marker = "\x{27ea}$brand v1 n=$s->{nonce} s=manual\x{27eb}";
    my $sentinel = "\x{27ea}/$brand n=$s->{nonce}\x{27eb}";
    my ($mre, $sre) = (skills::spec::marker_re(), skills::spec::sentinel_re());
    die "marker does not match the spec grammar\n" if ($mre && $marker !~ $mre) || ($sre && $sentinel !~ $sre);
    (my $btxt = $body) =~ s/\s+\z//;
    # CR-F9 (D-18 B8): the whole file is written and read back under a temp name first;
    # only then is the handoff-turn claim made, and the file is linked into place (an
    # exclusive create). A failed write or read-back leaves no claim behind.
    my ($path, $content);
    for (1 .. 5) {
        $path = $claimed // skills::util::unique_path($bucket, $s->{stem}, '.md');
        (my $bb = $btxt) =~ s/\@self\@/$path/g;
        $content = $fm . $marker . "\n" . $bb . "\n" . $sentinel . "\n";
        my $tmp = "$bucket/.$s->{stem}.md.publish-$$-" . int(rand(1e6));
        my $placed = eval {
            skills::util::write_excl($tmp, $content, 0600) or die "publish tmp exists: $tmp\n";
            my $back = skills::util::read_file($tmp);
            my @tail = grep { /\S/ } split /\n/, skills::util::text($back // '');
            die "read-back failed: $path\n" unless defined $back && skills::util::sha256_hex($back) eq skills::util::sha256_hex($content)
                && @tail && $tail[-1] eq $sentinel;
            if ($ht && defined $sid_dir && !defined $claimed) {
                # One handoff per plugin handoff turn: the claim comes before the file (D-18 B8).
                my ($ok, $have) = skills::core::ht_mark_published($sid_dir, $ht, $path);
                if (!$ok) { unlink $tmp; _refuse($ctx, $row, "handoff-exists $have") }
            }
            _place($tmp, $path, $content, $ht);
        };
        my $err = $@;
        unlink $tmp if -e $tmp;
        die $err unless defined $placed;
        last if $placed;
        undef $path;
    }
    die "no free handoff name\n" unless $path;
    skills::util::write_excl("$dir/published", "$path\n", 0600);

    # ---- U3-01: the checked approval lines' hashes, read from the placed file, in the store's
    # plugin-owned record; without it every line of this handoff is context only (re-ask).
    if (@{ $ap->{checked} || [] }) {
        my $pd = skills::store::read_doc($path);
        my ($n, $hwhy) = $pd ? skills::approvals::record_hashes($ctx, $pd, $ap->{checked}, $ap->{origins}) : (0, q(read-back));
        $row->{approvals}{hashed} = $n if $row->{approvals};
        if ($hwhy) {
            skills::cli::say("ADVISORY approval-hash-unrecorded $hwhy (the approvals of this handoff are context only)");
            $row->{lint_rules} = [ sort(@{ $row->{lint_rules} }, 'approval-hash-unrecorded') ];
        }
    }

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
    my $cmd = defined $job->{command} ? skills::core::recipe_command($job->{command})
            : '(withheld: ' . join(',', @{ ref $job->{command_withheld} eq 'ARRAY' ? $job->{command_withheld} : ['secret'] }) . ')';
    if ($t =~ /^\s*command:/m) { $t =~ s/^(\s*)command:[^\n]*/$1command: $cmd/m }
    else { $t =~ s/^(\s*item:[^\n]*\n)/$1command: $cmd\n/m }
    $t =~ s/^(\s*item:[^\n]*\n)/$1job: $rid · recorded\n/m;
    return $t;
}

# Link the checked temp file to the handoff path, never over an existing file: 1 placed,
# 0 the name is taken (try the next one; after a handoff-turn claim it dies instead).
# A file system without hard links falls back to an exclusive create of the same bytes
# (CR-F9: never a rename, which would replace a file made in the gap), read back.
# DP-28 (CR-F9 residual): when the fallback's write or read-back fails after its own exclusive
# open made the file, that file (the publish's own partial, checked by device and inode, never
# anything else) is removed and the publish dies, so a retry of the stage finds the claim with
# no file and fills it (_claimed_free). A partial left by a killed process stays (D-8):
# handoff-state then answers publish-failed and nothing replaces it.
# Test seams (STORE_TEST_MODE=1 only): STORE_TEST_PUBLISH_NOLINK=1 takes the fallback as on a
# file system without hard links; STORE_TEST_PUBLISH_FAIL=after-create fails right after the
# exclusive open, as a full disk would.
sub _place {
    my ($tmp, $path, $content, $ht) = @_;
    my $tm = skills::util::test_mode();
    my $nolink = $tm && ($ENV{STORE_TEST_PUBLISH_NOLINK} // '') eq '1';
    return 1 if !$nolink && link($tmp, $path);
    my $eexist = $nolink ? 0 : $!{EEXIST};
    if ($eexist || -e $path || -l $path) {
        die "handoff name taken after the handoff-turn claim: $path\n" if $ht;
        return 0;
    }
    my $fh;
    if (!sysopen($fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
        die "create $path: $!\n" unless $!{EEXIST};
        die "handoff name taken after the handoff-turn claim: $path\n" if $ht;
        return 0;
    }
    my @mine = (stat $fh)[0, 1];
    my $ok = eval {
        binmode $fh;
        die "write $path: no space left on device (test)\n" if $tm && ($ENV{STORE_TEST_PUBLISH_FAIL} // '') eq 'after-create';
        my $bytes = skills::util::bytes($content);
        my $off = 0;
        while ($off < length $bytes) {
            my $n = syswrite($fh, $bytes, length($bytes) - $off, $off);
            die "write $path: $!\n" unless defined $n;
            $off += $n;
        }
        close($fh) or die "close $path: $!\n";
        undef $fh;
        chmod 0600, $path;
        my $back = skills::util::read_file($path);
        die "read-back failed: $path\n" unless defined $back && $back eq $bytes;
        1;
    };
    if (!$ok) {
        my $err = $@ || "place failed: $path\n";
        close $fh if $fh;
        my @now = lstat $path;
        unlink $path if @now && -f _ && $now[0] == $mine[0] && $now[1] == $mine[1];
        die $err;
    }
    return 1;
}

# CR-F9: the handoff-turn claim names a path this retry may still fill: nothing is there
# (no file, no link), and it is the name this stage's publish picks (its bucket, its stem,
# an optional -N), so it was claimed by an earlier publish of the same stage.
sub _claimed_free {
    my ($p, $s) = @_;
    return 0 if -e $p || -l $p;
    return 0 unless defined $s->{bucket} && defined $s->{stem};
    return 0 unless File::Basename::dirname($p) eq $s->{bucket};
    return File::Basename::basename($p) =~ /\A\Q$s->{stem}\E(?:-[0-9]+)?\.md\z/ ? 1 : 0;
}

# The 1-based number of this publish call on the stage (T-TEXT E7): one line appended to the
# stage's attempts.log (O_APPEND under flock), then the lines counted.
sub _attempt {
    my ($dir) = @_;
    my $f = "$dir/attempts.log";
    eval { skills::util::append_line($f, skills::util::iso_local() . "\n") } or return undef;
    my $t = skills::util::read_file($f) // '';
    my $n = () = $t =~ /\n/g;
    return $n || undef;
}

# sha256/8 of the built handoff template the skill reads (T-TEXT E7), or undef without one.
sub _template_rev {
    my $h = skills::util::sha256_file(skills::ctx::plugin_root() . '/skills/handoff/references/handoff-template.md');
    return defined $h ? substr($h, 0, 8) : undef;
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

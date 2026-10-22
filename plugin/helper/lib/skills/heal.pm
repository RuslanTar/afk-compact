package skills::heal;
# lib/skills/heal.pm: `heal-check --origin SID --item ID [--bump]` (resume R5
# restart gate; TPL §4.4; S-11; MOD §7 heal counters). Prints `ok <recipe>|job:<id>`
# and `run:` only for a job the plugin recorded, else `REFUSED: <reason>`. At most
# 1 restart per resume and 2 per chain; the recipe script's sha256 must equal its
# MANIFEST row. --bump counts the restart before it starts (locked read-modify-write).
#
# Every item (CR-F13, DP-27: Dev-5 wins over the old same-session restart gate, so no
# recipe that came only from handoff text is ever `ok`): `signal:` lines V1-V7
# (skills/jobs.pm), then
#   verdict: <status> · confidence <high|low> · effects <class>[ · would-relaunch]
# then `ok <recipe|job:<id>>` and `run: <line>` (the recorded command byte for byte,
# `cd '<cwd>' && ` in front only when the cwd differs), or `REFUSED: <reason>` followed,
# for a question, by `ask-command:` and `ask-source: recorded|handoff`. A shell may
# relaunch by itself only with relaunch_auto on, relation same-session or successor
# (recomputed from the lineage; no relation flag exists), status LOST with confidence
# high (or FAILED with its record and command verified), effects none, local (an allowlisted
# single command, Q-J1-1, S-SETTINGS C) or prod-read with unattended_prod_reads `allow`
# (S-SETTINGS B; prod-write always asks), recipe class auto or no recipe,
# the recipe sha matching MANIFEST, and the counters. The helper never runs the command:
# the model runs `run:` through the Bash tool, so the permission system judges it.
# --bump also stores the run line's sha as pending, so the next recorded job with that
# command is marked relaunch_of (lib/jobrec.pm).
# Refusal precedence (REVIEW B-11): recipe-not-local -> relation -> mode-off | shadow ->
# recipe-mismatch -> the signals and gates. recipe-not-local (D-12): the origin's
# handoff is only a repository export or an imported copy; a recipe is never read from
# the repository.
use strict;
use warnings;
use utf8;
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::store;
use skills::gitfacts;
use skills::jobs;
use Cwd ();

our $PER_RESUME = 1;
our $PER_CHAIN  = 2;

# Recipes under <evidence dir>/restart/: [{bn, rid, class, path, script, text}]
sub recipes_in {
    my ($edir) = @_;
    my @out;
    for my $f (skills::util::list_dir("$edir/restart")) {
        next unless $f =~ /\.md\z/;
        my $p = "$edir/restart/$f";
        my $t = skills::util::read_text($p, 65536) // next;
        my %r = (path => $p, text => $t);
        if ($t =~ /^\s*item:\s*(B-\d+)(.*)$/m) {
            my ($bn, $rest) = ($1, $2);
            $r{bn} = $bn;
            ($r{rid}) = $rest =~ /runtime id\s+([^\s\x{b7}]+)/;
            ($r{class}) = $rest =~ /class\s+(auto|ask|never)\b/;
        }
        ($r{script}) = $t =~ /^\s*script:\s*(\S+)/m;
        undef $r{script} if defined $r{script} && $r{script} =~ /\Anone\z/i;
        push @out, \%r if $r{bn};
    }
    return \@out;
}

# match | differs | missing | none — the script against its MANIFEST row.
sub script_state {
    my ($r, $edir) = @_;
    return 'none' unless $r->{script};
    my $bucket = $edir =~ s{/evidence/[^/]+\z}{}r;
    my $abs = $r->{script} =~ m{\A/} ? $r->{script} : "$bucket/$r->{script}";
    my $rows = skills::store::read_manifest("$edir/MANIFEST.tsv") || [];
    my ($row) = grep { ($_->{copy_path} // '') eq $abs } @$rows;
    return 'missing' unless $row && -f $abs;
    my $sha = skills::util::sha256_file($abs) // '';
    return $sha eq ($row->{sha256} // '') ? 'match' : 'differs';
}

sub recipe_state {
    my ($r, $edir) = @_;
    my $rows = skills::store::read_manifest("$edir/MANIFEST.tsv") || [];
    my ($row) = grep { ($_->{copy_path} // '') eq $r->{path} } @$rows;
    return 'missing' unless $row;
    return (skills::util::sha256_hex($r->{text}) eq ($row->{sha256} // '')) ? 'match' : 'differs';
}

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'origin=s', 'item=s', 'bump');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--origin <session id>') unless skills::ctx::valid_sid($o->{origin});
    die skills::cli::usage('--item <runtime id>') unless defined $o->{item} && $o->{item} =~ /\A[A-Za-z0-9._:-]{1,64}\z/;
    my ($origin, $item) = ($o->{origin}, $o->{item});
    my $ctx = skills::ctx::new({});
    my $id = skills::ctx::resolve_sid($ctx, undef);
    my $row = { origin_sid => $origin, item => $item, bumped => ($o->{bump} ? \1 : \0), count => undef };

    my ($recipe, $edir, $docs) = find_recipe($ctx, $origin, $item);
    my $refuse = sub {
        my ($why, @after) = @_;
        $row->{result} = "REFUSED:$why";
        $ctx->log('heal', $row);
        die skills::cli::refuse($why, @after);
    };
    $refuse->('recipe-not-local') if !$recipe && not_local($ctx, $origin, $docs);

    # CR-F13 (DP-27, Dev-5): every item goes through the Dev-1 re-verification. `ok` needs a
    # job the plugin recorded, so a command found only in the handoff (no record: mod off,
    # a subagent's shell, a refused record, a row in inflight.md, a mistyped kind) is never
    # handed back as runnable; it is refused with `ask-source: handoff`.
    my $task = $recipe ? ($recipe->{rid} // $item) : $item;
    return shell($ctx, $o, $id, $origin, $item, $task, $recipe, $edir, $row, $refuse);
}

# ---------------------------------------------------------------- Dev-1 shells

sub shell {
    my ($ctx, $o, $id, $origin, $item, $task, $recipe, $edir, $row, $refuse) = @_;
    my $rl = skills::core::relaunch();
    my $cwd = skills::util::cwd();
    my $rel = relation($ctx, $id, $origin);
    my $v = skills::jobs::verify($ctx, origin => $origin, task => $task, recipe => $recipe, relaunch => $rl, cwd => $cwd,
                                 current => { sid => ($id->{degraded} ? undef : $id->{sid}), pid => $id->{pid}, lstart => $id->{lstart} });
    my $rec = $v->{record};
    # A consent or protective value given as a flag or env, or under a foreign config dir, did
    # not count (DP-3, CR-F34): say so, so the question can name the settings file.
    skills::cli::say("note: $_") for skills::core::settings_notes(qw(relaunch_auto relaunch_allow unattended_prod_reads prod_patterns));
    skills::cli::say(skills::jobs::signal_line($_, $v->{signals}{$_})) for @skills::jobs::SIGNALS;
    @$row{qw(verdict confidence effects mode relation new_task_id)} = ($v->{status}, $v->{confidence}, $v->{effects}, $rl->{auto}, $rel, undef);
    $row->{signals} = skills::jobs::states($v);
    $row->{item} = $task;
    # The production class id only (prod-token, user-prod-<n>), never the command (S-SETTINGS B).
    $row->{prod_class} = $v->{prod_class} if defined $v->{prod_class};

    # Questions name the command and where it came from; a withheld one is never printed.
    my $rcmd = $recipe && $recipe->{text} =~ /^\s*command:[ \t]*(.*?)[ \t]*$/m ? $1 : undef;
    my @ask;
    if ($rec && !defined $rec->{command}) { @ask = ('ask-command: none (the command held a credential-like value; re-launch it yourself)', 'ask-source: recorded') }
    elsif ($rec) { @ask = ('ask-command: ' . ($v->{run_line} // $rec->{command}), 'ask-source: recorded') }
    elsif (defined $rcmd && $rcmd ne '') { @ask = ("ask-command: $rcmd", 'ask-source: handoff (written in the handoff, not recorded by the plugin)') }

    my $gate = _gate($v, $rl, $recipe, $edir, $rcmd);
    my $would = !defined $gate && $rl->{auto} eq 'shadow';
    skills::cli::say(sprintf('verdict: %s · confidence %s · effects %s%s', $v->{status}, $v->{confidence}, $v->{effects}, $would ? ' · would-relaunch' : ''));

    my %report = map { $_ => 1 } qw(running-elsewhere running leftover done-unreported stopped);
    $refuse->('relation', @ask) unless $rel eq 'same-session' || $rel eq 'successor';
    $refuse->('mode-off', @ask) if $rl->{auto} eq 'off';
    $refuse->('shadow', @ask) if $rl->{auto} eq 'shadow';
    if (defined $gate) {
        my @after = $report{$gate} ? () : @ask;
        push @after, "collect: $v->{output}" if $gate eq 'done-unreported' && defined $v->{output};
        $refuse->($gate, @after);
    }

    # Counters, then the pending sha of the line the model will run.
    my $ckey = $recipe ? ($recipe->{rid} // $recipe->{bn}) : $task;
    my ($ok, $res) = _count($ctx, $id, $origin, $ckey, $o->{bump});
    $row->{item} = $res->{key} // $row->{item};
    $refuse->('counter', @ask) unless $ok;
    $row->{count} = $res->{chain};
    $refuse->('counter', @ask) if $res->{refused};
    if ($o->{bump}) {
        my $d = skills::core::sid_dir();
        skills::core::job_add_pending($d, { sha256 => skills::util::sha256_hex($v->{run_line}), origin_sid => $origin,
                                            task_id => $task, epoch => $rec->{epoch} }) if defined $d;
    }
    $row->{result} = 'ok';
    $ctx->log('heal', $row);
    skills::cli::say('ok ' . ($recipe ? $recipe->{path} : "job:$task"));
    skills::cli::say("run: $v->{run_line}");
    return 0;
}

# The first failed gate after relation and mode (REVIEW B-11 order: recipe-mismatch, then
# the signals): report-only statuses, a withheld command (it never relaunches by itself),
# the ask statuses, then the effects class, the recipe class and sha, the run line.
sub _gate {
    my ($v, $rl, $recipe, $edir, $rcmd) = @_;
    my $rec = $v->{record};
    return 'recipe-mismatch' if $rec && defined $rec->{command} && defined $rcmd && $rcmd ne skills::core::recipe_command($rec->{command});
    my %report = ('RUNNING-ELSEWHERE' => 'running-elsewhere', RUNNING => 'running', LEFTOVER => 'leftover',
                  'DONE-UNREPORTED' => 'done-unreported', STOPPED => 'stopped');
    return $report{ $v->{status} } if $report{ $v->{status} };
    return 'command-withheld' if $rec && !defined $rec->{command};
    return 'ended-unexplained' if $v->{status} eq 'ENDED-UNEXPLAINED';
    return 'killed' if $v->{status} eq 'KILLED';
    if ($v->{status} eq 'LOST') {
        return 'lost-low' unless $v->{confidence} eq 'high';
    } elsif ($v->{status} eq 'FAILED') {
        return 'failed' unless ($v->{signals}{V1}[0] eq 'pass' && $v->{signals}{V7}[0] eq 'pass');
    } else {
        return 'not-lost';
    }
    return 'command-withheld' unless $rec && defined $rec->{command};
    # S-SETTINGS B: a production read relaunches by itself only with unattended_prod_reads
    # `allow` (a consent key, read from the settings file only); a production write never does.
    if ($v->{effects} eq 'local') { return 'effects-local' unless $rl->{allow_active} }
    elsif ($v->{effects} eq 'prod-read') { return 'effects-prod-read' unless (($v->{prod} || {})->{reads} // 'forbid') eq 'allow' }
    elsif ($v->{effects} ne 'none') { return "effects-$v->{effects}" }
    if ($recipe) {
        return 'class' unless ($recipe->{class} // 'ask') eq 'auto';
        return 'sha' if recipe_state($recipe, $edir) ne 'match';
        my $ss = script_state($recipe, $edir);
        return 'sha' unless $ss eq 'match' || $ss eq 'none';
    }
    return 'cwd-quote' unless defined $v->{run_line};
    return undef;
}

# The resume relation of the origin to this session (A-6 lineage, 3 hops; the helper
# recomputes it, there is no flag): same-session | successor | other.
sub relation {
    my ($ctx, $id, $origin) = @_;
    return 'other' if $id->{degraded};
    return 'same-session' if $id->{sid} eq $origin;
    return (grep { $_->{sid} eq $origin } @{ skills::ctx::chain($ctx, $id->{sid}) }) ? 'successor' : 'other';
}

# D-12 (AT-RM-11): the origin's handoffs here are only imported copies of exports, or the
# origin has none here but an export under this worktree's repository root.
sub not_local {
    my ($ctx, $origin, $docs) = @_;
    if (@{ $docs || [] }) { return (grep { !skills::store::imported($_) } @$docs) ? 0 : 1 }
    my $w = skills::gitfacts::where(skills::util::cwd());
    return 0 unless $w->{in_git} && $w->{worktree};
    my $dd = skills::core::declaration($w->{worktree});
    return 0 unless $dd->{present} && $dd->{valid};
    return (grep { ($_->{fm}{session_id} // '') eq $origin } @{ skills::store::export_docs($w->{worktree}, $dd->{root}, '') }) ? 1 : 0;
}

# Count one restart of item $ckey under the lock; returns ($ok, {refused, chain, key}).
sub _count {
    my ($ctx, $id, $origin, $ckey, $bump) = @_;
    my $key = $id->{pid} ? "pid:$id->{pid}:" . ($id->{lstart} // '') : $id->{sid};
    $ckey =~ s/[^A-Za-z0-9._:-]/_/g;
    my $dir = "$ctx->{watch}/heal/$origin";
    skills::util::mkdir_p($dir);
    my $file = "$dir/$ckey.count";
    my ($ok, $res) = skills::core::with_lock("$file.lock", skills::core::lock_owner($id->{sid}, 'main'), sub {
        my $c = eval { skills::util::json_decode(skills::util::read_file($file, 65536)) };
        $c = {} unless ref $c eq 'HASH';
        $c->{chain} //= 0;
        $c->{by_resume} = {} unless ref $c->{by_resume} eq 'HASH';
        my $mine = $c->{by_resume}{$key} // 0;
        return { refused => 1, chain => $c->{chain} } if $c->{chain} >= $PER_CHAIN || $mine >= $PER_RESUME;
        if ($bump) {
            $c->{chain}++;
            $c->{by_resume}{$key} = $mine + 1;
            skills::util::write_replace($file, skills::util::json_encode($c) . "\n", 0600);
        }
        return { refused => 0, chain => $c->{chain} };
    });
    $res = {} unless ref $res eq 'HASH';
    $res->{key} = $ckey;
    return ($ok, $res);
}

# The newest handoff of the origin session that has a recipe for the item
# (B-n or runtime id). Returns ($recipe, $evidence_dir, [the origin's docs, newest first]).
sub find_recipe {
    my ($ctx, $origin, $item) = @_;
    my %b;
    my $pin = skills::ctx::pin_read($ctx, $origin);
    $b{ $pin->{bucket_path} } = 1 if $pin && $pin->{bucket_path};
    my $w = skills::gitfacts::where(skills::util::cwd());
    $b{$_} = 1 for @{ skills::store::buckets($ctx->{root}, $w->{repo}) };
    my @docs = sort { ($b->{epoch} // 0) <=> ($a->{epoch} // 0) }
               grep { ($_->{fm}{session_id} // '') eq $origin } map { @{ skills::store::docs_in($_) } } sort keys %b;
    for my $d (@docs) {
        next if skills::store::imported($d);
        my $edir = skills::store::bucket_of($d->{path}) . '/evidence/' . skills::store::stem_of($d->{path});
        for my $r (@{ recipes_in($edir) }) {
            return ($r, $edir, \@docs) if $r->{bn} eq $item || (defined $r->{rid} && $r->{rid} eq $item);
        }
    }
    return (undef, undef, \@docs);
}

1;

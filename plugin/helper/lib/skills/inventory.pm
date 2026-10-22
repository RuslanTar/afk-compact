package skills::inventory;
# lib/skills/inventory.pm: `inventory <handoff>` (resume R5a; RDN; OD-19:
# no task tools). Prints the last Stop sidecar of the handoff's session,
# task outputs (size, mtime), In-flight rows with their probe paths, recorded
# pids with a start-time match, listening ports, recipes and heal counters.
# 2026-10-21 rulings: the sidecar slot is the one of the highest seq, never the newest
# mtime (DP-13); each job the plugin recorded for the session prints one `job:` line with
# its re-verification signals (Dev-1 D3, skills/jobs.pm; read-only); a document that is
# not local (a repository export or an imported copy, D-12) is never probed: no pid,
# port, path or start-time matching, since a foreign pid could match an unrelated
# local process.
use strict;
use warnings;
use utf8;
use Socket ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::store;
use skills::begin;
use skills::heal;
use skills::jobs;
use skills::core;
use Cwd ();

sub run {
    my ($argv) = @_;
    skills::cli::opts($argv);
    die skills::cli::usage('inventory <handoff>') unless @$argv == 1;
    my $path = skills::util::abs_path($argv->[0]);
    die skills::cli::refuse('not-found') unless defined $path && -f $path;
    my $d = skills::store::read_doc($path);
    my $ctx = skills::ctx::new({});
    my $hs = $d->{fm}{session_id} // '';
    $hs = '' unless skills::ctx::valid_sid($hs);
    if (skills::store::is_export($d) || skills::store::imported($d) || !_under_root($ctx, $path)) {
        skills::cli::say('not local: ' . (skills::store::imported($d) ? 'an imported copy of a repository export' : 'a repository export or a file outside the handoff store'));
        skills::cli::say('in-flight: other machine: not probed');
        skills::cli::say('evidence: not on this machine');
        return 0;
    }

    # Sidecar ring of the handoff's session: the slot of the highest seq (DP-13).
    my $watch = skills::core::watch_dir() // $ctx->{watch};
    my ($sc, $slot_path) = $hs ne '' ? skills::core::sidecar_newest("$watch/$hs") : ();
    if ($sc && $slot_path) {
        my $tasks = skills::begin::sidecar_tasks($sc);
        skills::cli::say(sprintf('sidecar: %s ts=%s tasks=%d', $slot_path, $sc->{ts} // '?', scalar @$tasks));
        for my $t (@$tasks) {
            my $line = join ' · ', 'task: ' . ($t->{id} // '?'), $t->{kind} // '?', $t->{status} // '?';
            $line .= ' · ' . _file($t->{output}) if defined $t->{output};
            skills::cli::say($line);
        }
    } else {
        skills::cli::say('sidecar: none');
    }

    # In-flight rows of the handoff, with the paths their probes name.
    my $in = 0;
    my %seen;
    for my $l (split /\n/, $d->{body}) {
        if ($l =~ /\A##\s+(.*)/ && $l !~ /\A###/) { $in = $1 =~ /\AIn flight/ ? 1 : 0; next }
        next unless $in;
        if ($l =~ /\A\|\s*(B-\d+)\s*(?:\x{b7}\s*([^|]*?))?\s*\|([^|]*)\|/) {
            my ($bn, $rid, $kindcell) = ($1, $2 // '', $3);
            my ($kind) = $kindcell =~ /\A\s*([a-z]+)/;
            my @cells = split /\|/, $l;
            my $restart = $cells[7] // '';
            my ($class) = $restart =~ /\b(auto|ask|never)\b/;
            skills::cli::say(join ' · ', "row: $bn", ($rid eq '' ? '?' : $rid), ($kind // '?'), 'class ' . ($class // 'ask'));
        }
        if ($l =~ /\ALeftover:\s*(\d+)\s*\x{b7}\s*(\d*)/) {
            my ($pid, $port) = ($1, $2);
            skills::cli::say("leftover pid: $pid alive=" . (kill(0, $pid) || $!{EPERM} ? 'yes' : 'no') . ' (start time not recorded)');
            skills::cli::say("port: $port listening=" . _listening($port)) if $port ne '';
        }
        while ($l =~ m{(/[^\s`'"|<>()]+)}g) {
            my $p = $1;
            $p =~ s/[.,:;]+\z//;
            next if $seen{$p}++ || $p =~ m{\A/(?:clear|exit)\z};
            skills::cli::say('path: ' . _file($p));
        }
    }

    # Recorded pids of the handoff's session, matched by start time.
    if ($hs ne '') {
        my $all = skills::ctx::records($ctx);
        for my $r (grep { ($_->{data}{session_id} // '') eq $hs && $_->{state} eq 'live' } @$all) {
            my $live = skills::ctx::record_live($ctx, $r, $all);
            my $state = $live ? 'yes' : (kill(0, $r->{pid}) || $!{EPERM} ? 'start-differs' : 'no');
            skills::cli::say("pid: $r->{pid} session " . skills::ctx::sid8($hs) . " live=$state");
        }
    }
    if (defined $d->{fm}{claude_pid} && $d->{fm}{claude_pid} =~ /\A\d+\z/) {
        skills::cli::say("claude_pid: $d->{fm}{claude_pid} (" . (kill(0, $d->{fm}{claude_pid}) || $!{EPERM} ? 'running; match by record above' : 'not running') . ')');
    }

    # Recipes, recorded jobs and counters.
    my $edir = skills::store::bucket_of($path) . '/evidence/' . skills::store::stem_of($path);
    if ($hs ne '') {
        my %recipe = map { ((defined $_->{rid} ? $_->{rid} : $_->{bn}) => $_) } @{ skills::heal::recipes_in($edir) };
        my %seen;
        my $id = skills::ctx::resolve_sid($ctx, undef);
        my $rl = skills::core::relaunch();
        for my $r (reverse @{ skills::core::job_rows("$watch/$hs") }) {
            next unless ($r->{ev} // '') eq 'job' && defined $r->{task_id} && !$seen{ $r->{task_id} }++;
            my $v = skills::jobs::verify($ctx, origin => $hs, task => $r->{task_id}, recipe => $recipe{ $r->{task_id} },
                                         relaunch => $rl, cwd => skills::util::cwd(),
                                         current => { sid => ($id->{degraded} ? undef : $id->{sid}), pid => $id->{pid}, lstart => $id->{lstart} });
            my $st = skills::jobs::states($v);
            skills::cli::say(join ' · ', "job: $r->{task_id}", 'recorded', 'read-only ' . ($r->{is_read_only} ? 'yes' : 'no'),
                'effects ' . $v->{effects}, 'output ' . ($r->{output_path} // 'none'),
                'verdict ' . $v->{status} . ' ' . $v->{confidence},
                'signals ' . join(' ', map { "$_=$st->{$_}" } @skills::jobs::SIGNALS));
        }
    }
    for my $r (@{ skills::heal::recipes_in($edir) }) {
        skills::cli::say(join ' · ', "recipe: $r->{bn}", 'runtime id ' . ($r->{rid} // '?'), 'class ' . ($r->{class} // 'ask'),
            $r->{path}, 'script sha ' . skills::heal::script_state($r, $edir));
    }
    if ($hs ne '') {
        my $hd = "$ctx->{watch}/heal/$hs";
        for my $f (grep { /\.count\z/ } skills::util::list_dir($hd)) {
            my $c = eval { skills::util::json_decode(skills::util::read_file("$hd/$f", 65536)) } || {};
            (my $item = $f) =~ s/\.count\z//;
            skills::cli::say("counter: $item chain=" . ($c->{chain} // 0));
        }
    }
    return 0;
}

# 1 when the path lies under the private handoff root (the store this machine owns).
sub _under_root {
    my ($ctx, $p) = @_;
    my $root = skills::util::abs_path($ctx->{root}) // $ctx->{root};
    my $real = skills::util::abs_path($p) // $p;
    return index($real, "$root/") == 0 ? 1 : 0;
}

sub _file {
    my ($p) = @_;
    my @st = stat $p;
    return "$p missing" unless @st;
    return sprintf('%s %d B mtime %s', $p, $st[7], skills::util::iso_local($st[9]));
}

# A bounded local TCP connect; nothing is sent.
sub _listening {
    my ($port) = @_;
    return 'unknown' unless $port =~ /\A\d+\z/ && $port > 0 && $port < 65536;
    socket(my $s, Socket::PF_INET(), Socket::SOCK_STREAM(), 0) or return 'unknown';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 1;
        my $r = connect($s, Socket::pack_sockaddr_in($port, Socket::inet_aton('127.0.0.1')));
        alarm 0;
        $r;
    };
    alarm 0;
    close $s;
    return $ok ? 'yes' : 'no';
}

1;

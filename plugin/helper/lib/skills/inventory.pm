package skills::inventory;
# lib/skills/inventory.pm: `inventory <handoff>` (resume R5a; RDN; OD-19:
# no task tools). Prints the last Stop sidecar of the handoff's session,
# task outputs (size, mtime), In-flight rows with their probe paths, recorded
# pids with a start-time match, listening ports, recipes and heal counters.
use strict;
use warnings;
use Socket ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::store;
use skills::begin;
use skills::heal;

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

    # Sidecar ring of the handoff's session.
    my $bg = "$ctx->{watch}/$hs/bg";
    my @slots = $hs ne '' ? grep { /\Aslot-\d+\.json\z/ } skills::util::list_dir($bg) : ();
    if (@slots) {
        my ($newest) = sort { (stat "$bg/$b")[9] <=> (stat "$bg/$a")[9] || $b cmp $a } @slots;
        my $sc = eval { skills::util::json_decode(skills::util::read_file("$bg/$newest", 262144)) } || {};
        my $tasks = skills::begin::sidecar_tasks($sc);
        skills::cli::say(sprintf('sidecar: %s ts=%s tasks=%d', "$bg/$newest", $sc->{ts} // '?', scalar @$tasks));
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
        if ($l =~ /\A\|\s*(B-\d+)\s*(?:\x{c2}\x{b7}\s*([^|]*?))?\s*\|([^|]*)\|/) {
            my ($bn, $rid, $kindcell) = ($1, $2 // '', $3);
            my ($kind) = $kindcell =~ /\A\s*([a-z]+)/;
            my @cells = split /\|/, $l;
            my $restart = $cells[7] // '';
            my ($class) = $restart =~ /\b(auto|ask|never)\b/;
            skills::cli::say(join ' · ', "row: $bn", ($rid eq '' ? '?' : $rid), ($kind // '?'), 'class ' . ($class // 'ask'));
        }
        if ($l =~ /\ALeftover:\s*(\d+)\s*\x{c2}\x{b7}\s*(\d*)/) {
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

    # Recipes and counters.
    my $edir = skills::store::bucket_of($path) . '/evidence/' . skills::store::stem_of($path);
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

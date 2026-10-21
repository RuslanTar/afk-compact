package jobrec;
# lib/jobrec.pm: Dev-1 job records (MOD-SPEC §7 "Job records"; BUILD-PLAN §3.1 `log
# --stream jobs`, §3.7). Owner: WP-core. The mod's main tool.call handler records each
# background shell after next(e) resolves and sends the raw fields on stdin; this file
# completes and writes one row to <watch>/<sid>/jobs.jsonl (O_APPEND, 0600):
#   job:  task_id · launched_at · owner {pid, lstart} (this session's live process
#         record) · cwd · command (literal; null when withheld) · command_sha256 ·
#         command_withheld [rule ids] · is_read_only (true only when core set it) ·
#         sandbox_disabled · backgrounded flag|user|timeout|other · output_path ·
#         output_path_source · output_path_candidates · relaunch_of · epoch
#   stop: task_id (a TaskStop call)
# Writer guard: accepted only when the helper's parent is the recorded Claude Code
# process (ppid = the live record's pid, start time matching); else REFUSED: jobs-caller.
# Residual (REVIEW B-16): a model-run `exec <store> log --stream jobs …` replaces its
# shell, so its parent is the Claude Code process too and the guard passes. Such a row
# can only claim a command; heal-check's V1 needs the origin transcript's own Bash
# tool_use with that command and backgroundTaskId, and the sidecar keeps the runtime's
# BackgroundTaskSummary.command as a sha (lib/sidecar.pm) for a second, runtime-owned
# cross-check. Secrets: the command is scanned at write; a HARD hit stores the sha256 and
# the rule ids, never the text, so such a job never relaunches by itself.
# Pending relaunches (heal-check --bump, WP-skills): <watch>/<sid>/jobs-pending.jsonl,
# one row per bumped relaunch {sha256 of the run line, origin_sid, task_id, epoch}. A job
# recorded later in the same session whose command has that sha gets relaunch_of and the
# next epoch; one still unmatched at a Stop is `relaunch_unmatched`.
use strict;
use warnings;

# Output path source (DP-2 / REVIEW A-2, probe P-D1-6). BackgroundTaskSummary has no
# output path (types :820-851) and result.backgroundOutputPath is set only for jobs kept
# by another process (types :21290). Two candidate sources are read and recorded for the
# probe; neither is used until P-D1-6 says which one holds:
#   result-text  the Bash tool.call result text names the output file
#   layout       the observed <tmp>/claude-<uid>/<cwd slug>/<sid>/tasks/<id>.output
# 'none' (today): output_path stays null and `/status` says automatic relaunch is
# inactive (no output path). Set it to the source the probe passed.
our $OUTPUT_PATH_SOURCE = 'none';
our %SOURCES = map { $_ => 1 } qw(none result-text layout);

our $ID_RE = qr/\A[A-Za-z0-9._:-]{1,128}\z/;
our %BACKGROUNDED = map { $_ => 1 } qw(flag user timeout other);
our $RESULT_TEXT_MAX = 4000;

sub jobs_path    { my ($sid_dir) = @_; return "$sid_dir/jobs.jsonl" }
sub pending_path { my ($sid_dir) = @_; return "$sid_dir/jobs-pending.jsonl" }

# owner(sid) -> the live process record of this session for the Claude Code process the
# helper runs under ({pid, lstart}), or undef. A record with an ended- twin does not count.
sub owner {
    my ($sid) = @_;
    return undef unless defined rc::root();
    my $c = rc::claude();
    my $sid8 = substr($sid, 0, 8);
    my $dir = sessions::by_pid();
    my %ended = map { /^(\d+-\d+)\.ended-([^.]+)\.json$/ ? ("$1/$2" => 1) : () } util::list_dir($dir);
    for my $f (reverse util::list_dir($dir)) {
        next unless $f =~ /^(\d+)-(\d+)\.live-\Q$sid8\E\.json$/;
        next if $ended{"$1-$2/$sid8"};
        next unless $1 == $c->{pid};
        my $j = eval { jsonc::decode(util::read_file("$dir/$f") // '') };
        next unless ref $j eq 'HASH' && ($j->{session_id} // '') eq $sid;
        next unless defined $j->{pid_lstart} && defined $c->{lstart} && $j->{pid_lstart} eq $c->{lstart};
        return { pid => 0 + $j->{pid}, lstart => $j->{pid_lstart} };
    }
    return undef;
}

# caller_ok(sid) -> (owner, undef) or (undef, reason): no-record | parent
sub caller_ok {
    my ($sid) = @_;
    my $o = owner($sid) // return (undef, 'no-record');
    my $pp = getppid();
    return (undef, 'parent') unless $pp == $o->{pid} && identity::alive($pp, $o->{lstart});
    return ($o, undef);
}

# cwd_slug(path) -> the project folder name Claude Code uses: every character that is not
# a letter or a digit becomes '-' (/Users/a/.claude -> -Users-a--claude)
sub cwd_slug { my ($p) = @_; (my $s = $p // '') =~ s/[^A-Za-z0-9]/-/g; return $s }

# Candidate readers (P-D1-6). Each returns an absolute path or undef.
sub path_from_result_text {
    my ($text, $task) = @_;
    return undef unless defined $text && !ref $text && $text ne '';
    my $t = substr($text, 0, $RESULT_TEXT_MAX);
    my @p = $t =~ m{(/[^\s'"`<>|;]+/tasks/[A-Za-z0-9._-]+\.output)\b}g;
    @p = grep { m{/\Q$task\E\.output$} } @p if defined $task && grep { m{/\Q$task\E\.output$} } @p;
    return $p[0] if @p;
    return $1 if $t =~ m{output (?:is being )?written to:?\s+(/[^\s'"`<>|;]+)};
    return undef;
}

sub path_from_layout {
    my ($sid, $cwd, $task) = @_;
    return undef unless defined $sid && defined $cwd && $cwd =~ m{^/} && defined $task && $task =~ $ID_RE;
    my $base = $^O eq 'darwin' ? '/private/tmp' : '/tmp';
    return "$base/claude-$</" . cwd_slug($cwd) . "/$sid/tasks/$task.output";
}

# output_path(raw, sid) -> (path or undef, source, candidates)
sub output_path {
    my ($in, $sid) = @_;
    my $rt = path_from_result_text($in->{result_text}, $in->{task_id});
    my $ly = path_from_layout($sid, $in->{cwd}, $in->{task_id});
    my $bo = (defined $in->{background_output_path} && !ref $in->{background_output_path}
              && $in->{background_output_path} =~ m{^/[^\n]{1,1024}$}) ? $in->{background_output_path} : undef;
    my $cand = jsonc::obj(
        result_text => (defined $rt ? jsonc::obj(path => $rt, exists => jsonc::bool(-e $rt)) : undef),
        layout      => (defined $ly ? jsonc::obj(path => $ly, exists => jsonc::bool(-e $ly)) : undef),
        background_output_path => $bo,
    );
    my $src = $SOURCES{$OUTPUT_PATH_SOURCE} ? $OUTPUT_PATH_SOURCE : 'none';
    my $path = $src eq 'result-text' ? $rt : $src eq 'layout' ? $ly : undef;
    return ($path, (defined $path ? $src : 'none'), $cand);
}

sub _bool_true { my ($v) = @_; return (jsonc::is_bool($v) && $v) || (defined $v && !ref $v && $v =~ /^(1|true)$/) ? 1 : 0 }

sub read_rows {
    my ($f) = @_;
    my @rows;
    for my $l (split /\n/, (util::read_file($f) // '')) {
        my $j = eval { jsonc::decode($l) };
        push @rows, $j if ref $j eq 'HASH';
    }
    return \@rows;
}

# The pending entry a new job with command sha `sha` fulfils: the newest one with that
# sha whose task no job row has named in relaunch_of yet.
sub _match_pending {
    my ($sid_dir, $sha) = @_;
    my $pend = read_rows(pending_path($sid_dir));
    return undef unless @$pend;
    my %done = map { (($_->{relaunch_of} // '') . "\t" . ($_->{command_sha256} // '') => 1) }
               grep { ($_->{ev} // '') eq 'job' } @{ read_rows(jobs_path($sid_dir)) };
    for my $p (reverse @$pend) {
        next unless ($p->{sha256} // '') eq $sha;
        next if $done{ ($p->{task_id} // '') . "\t$sha" };
        return $p;
    }
    return undef;
}

# complete(raw row, sid, owner) -> (row object) or (undef, 'usage: ...')
sub complete {
    my ($in, $sid, $owner) = @_;
    my $kind = $in->{kind} // 'job';
    return (undef, 'usage: kind job|stop') unless $kind =~ /^(job|stop)$/;
    my $task = $in->{task_id};
    return (undef, 'usage: task_id missing or malformed') unless defined $task && !ref $task && $task =~ $ID_RE;
    my $env = rc::envelope(actor => 'main', writer => 'helper');
    if ($kind eq 'stop') {
        return (log::row('stop', [kind => 'stop', task_id => $task], $env));
    }
    my $cmd = $in->{command};
    return (undef, 'usage: command missing') unless defined $cmd && !ref $cmd && $cmd ne '';
    my $sha = sha::hex256($cmd);
    my $hits = secrets::scan($cmd);
    my @hard = map { $_->{rule} } grep { $_->{class} eq 'HARD' } @$hits;
    my $cwd = (defined $in->{cwd} && !ref $in->{cwd} && $in->{cwd} =~ m{^/}) ? $in->{cwd} : undef;
    my $bg = (defined $in->{backgrounded} && $BACKGROUNDED{ $in->{backgrounded} }) ? $in->{backgrounded} : 'other';
    my $launched = (defined $in->{launched_at} && defined util::parse_iso($in->{launched_at})) ? $in->{launched_at} : util::iso(util::now());
    my ($opath, $osrc, $cand) = output_path({ %$in, cwd => $cwd }, $sid);
    my $d = rc::sid_dir();
    my $pend = defined $d ? _match_pending($d, $sha) : undef;
    my $epoch = $pend ? (($pend->{epoch} // 1) =~ /^\d+$/ ? $pend->{epoch} + 1 : 2) : 1;
    my $build = sub {
        my ($command, $withheld) = @_;
        return log::row('job', [
            kind => 'job', task_id => $task, launched_at => $launched,
            owner => jsonc::obj(pid => $owner->{pid}, lstart => $owner->{lstart}),
            cwd => $cwd, command => $command, command_sha256 => $sha, command_withheld => $withheld,
            is_read_only => jsonc::bool(_bool_true($in->{is_read_only})),
            sandbox_disabled => jsonc::bool(_bool_true($in->{sandbox_disabled})),
            backgrounded => $bg, output_path => $opath, output_path_source => $osrc, output_path_candidates => $cand,
            relaunch_of => ($pend ? $pend->{task_id} : undef), epoch => 0 + $epoch,
        ], $env);
    };
    my $row = @hard ? $build->(undef, \@hard) : $build->($cmd, undef);
    # A command too long for one row is withheld like a secret: the job never relaunches by itself.
    my $len = do { my $l = jsonc::encode($row); utf8::encode($l) if utf8::is_utf8($l); length($l) + 1 };
    $row = $build->(undef, ['row-too-large']) if $len > $log::MAX;
    return ($row);
}

# add_pending(sid_dir, {sha256, origin_sid, task_id, epoch}) -> 1 (heal-check --bump)
sub add_pending {
    my ($sid_dir, $p) = @_;
    die "jobrec: pending needs sha256\n" unless defined $p->{sha256} && $p->{sha256} =~ /\A[0-9a-f]{64}\z/;
    my $row = log::row('relaunch_pending', [sha256 => $p->{sha256}, origin_sid => $p->{origin_sid}, task_id => $p->{task_id},
                                            epoch => (defined $p->{epoch} ? 0 + $p->{epoch} : 1)],
                       rc::envelope(actor => 'main', writer => 'helper'));
    log::append(pending_path($sid_dir), $row);
    return 1;
}

# unmatched(sid_dir) -> [pending rows no recorded job has fulfilled]
sub unmatched {
    my ($sid_dir) = @_;
    my $pend = read_rows(pending_path($sid_dir));
    return [] unless @$pend;
    my %done = map { (($_->{relaunch_of} // '') . "\t" . ($_->{command_sha256} // '') => 1) }
               grep { ($_->{ev} // '') eq 'job' } @{ read_rows(jobs_path($sid_dir)) };
    return [grep { !$done{ ($_->{task_id} // '') . "\t" . ($_->{sha256} // '') } } @$pend];
}

# on_stop(sid_dir): one relaunch_unmatched row per pending entry still unmatched.
sub on_stop {
    my ($sid_dir) = @_;
    return 0 unless -f pending_path($sid_dir);
    my $n = 0;
    for my $p (@{ unmatched($sid_dir) }) {
        my $sha8 = substr($p->{sha256} // '', 0, 8);
        next unless rc::once('relaunch_unmatched.' . ($p->{task_id} // '-') . ".$sha8");
        rc::emit('relaunch_unmatched', [task_id => $p->{task_id}, origin_sid => $p->{origin_sid}, sha8 => $sha8]);
        $n++;
    }
    return $n;
}

# record_of(sid_dir, task_id) -> the newest job row of that task, or undef
sub record_of {
    my ($sid_dir, $task) = @_;
    return undef unless defined $sid_dir && defined $task;
    my $best;
    for my $r (@{ read_rows(jobs_path($sid_dir)) }) {
        $best = $r if ($r->{ev} // '') eq 'job' && ($r->{task_id} // '') eq $task;
    }
    return $best;
}

1;

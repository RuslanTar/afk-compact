# cmd/log.pl: `log --sid S [--stream mod|paths|jobs] (--json ROW | --stdin)` (BUILD-PLAN
# §3.1, ROOT-RULINGS F2-6). Owner: WP-core.
# mod (default): O_APPEND writes <= 4 KB per row to <watch>/<sid>.jsonl; paths: to
# <watch>/<sid>/paths.jsonl. A row is the caller's (already enveloped), kept as given after
# a parse check. `--stdin` reads one JSON object per line (blank lines skipped) and appends
# them all in one locked write, so the mod sends one batch per tool call; every line is
# checked before anything is written. A row > 4 KB -> exit 3 `REFUSED: row-too-large`
# (nothing written); a batch over 1 MB -> exit 3 `REFUSED: batch-too-large`.
# jobs (Dev-1, `--stdin` only): the mod's raw fields of a background shell (or a TaskStop),
# completed by lib/jobrec.pm and appended to <watch>/<sid>/jobs.jsonl, whatever the
# watcher mode. Accepted only from the recorded Claude Code parent, else exit 3
# `REFUSED: jobs-caller` and one `jobs_caller_refused {reason}` row; the command is
# secret-scanned before it is written (a HARD hit keeps only its sha256 and rule ids).
use strict;
use warnings;

package cmd_log;

my @STREAM_FLAGS = qw(sid stream json root log-dir disposable-root);
our $BATCH_MAX = 1024 * 1024;

# check(line) -> (bytes, undef) or (undef, 'usage: ...' | 'REFUSED: ...')
sub _check {
    my ($line, $what) = @_;
    $line =~ s/\r?\n+\z//;
    return (undef, "usage: $what must be one line") if index($line, "\n") >= 0;
    my $j = eval { jsonc::decode($line) };
    return (undef, "usage: $what is not a JSON object") unless ref $j eq 'HASH';
    my $bytes = $line;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    return (undef, 'REFUSED: row-too-large') if length($bytes) + 1 > $log::MAX;
    return ($bytes, undef);
}

sub run {
    my ($opt) = args::parse(\@_, known => \@STREAM_FLAGS, bools => ['stdin']);
    my $sid = args::init_sid($opt);
    die "usage: give --json ROW or --stdin, not both\n" if $opt->{stdin} && defined $opt->{json};
    die "usage: --stream jobs takes --stdin\n" if ($opt->{stream} // '') eq 'jobs' && !$opt->{stdin};
    args::need($opt, 'json') unless $opt->{stdin};
    my $stream = $opt->{stream} // 'mod';
    die "usage: --stream mod|paths|jobs\n" unless $stream =~ /^(mod|paths|jobs)$/;
    return _jobs($sid) if $stream eq 'jobs';
    my @rows;
    if ($opt->{stdin}) {
        binmode(STDIN, ':raw');
        my $raw = '';
        my $n = read(STDIN, $raw, $BATCH_MAX + 1) // 0;
        if ($n > $BATCH_MAX) { args::out('REFUSED: batch-too-large'); return 3 }
        my $k = 0;
        for my $line (split /\n/, $raw) {
            $k++;
            next unless $line =~ /\S/;
            my ($b, $err) = _check($line, "stdin line $k");
            if (defined $err) {
                die "$err\n" if $err =~ /^usage:/;
                args::out($err);
                return 3;
            }
            push @rows, $b;
        }
    } else {
        my ($b, $err) = _check($opt->{json}, '--json');
        if (defined $err) {
            die "$err\n" if $err =~ /^usage:/;
            args::out($err);
            return 3;
        }
        push @rows, $b;
    }
    my $path = rc::stream_path($stream);
    if (!defined $path) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    util::append($path, join('', map { "$_\n" } @rows)) if @rows;
    return 0;
}

sub _read_stdin {
    binmode(STDIN, ':raw');
    my $raw = '';
    my $n = read(STDIN, $raw, $BATCH_MAX + 1) // 0;
    return $n > $BATCH_MAX ? undef : $raw;
}

sub _jobs {
    my ($sid) = @_;
    my $d = rc::sid_dir();
    if (!defined $d) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    my ($owner, $why) = jobrec::caller_ok($sid);
    if (!$owner) {
        rc::emit('jobs_caller_refused', [reason => $why]);
        args::out('REFUSED: jobs-caller');
        return 3;
    }
    my $raw = _read_stdin();
    if (!defined $raw) { args::out('REFUSED: batch-too-large'); return 3 }
    my @rows;
    my $k = 0;
    for my $line (split /\n/, $raw) {
        $k++;
        next unless $line =~ /\S/;
        my $in = eval { jsonc::decode($line) };
        die "usage: stdin line $k is not a JSON object\n" unless ref $in eq 'HASH';
        my ($row, $err) = jobrec::complete($in, $sid, $owner);
        die "$err (stdin line $k)\n" if defined $err;
        push @rows, $row;
    }
    # One row at a time: a later row's relaunch match reads the rows written before it.
    log::append(jobrec::jobs_path($d), $_) for @rows;
    return 0;
}

exit(args::main(\&run, @ARGV));

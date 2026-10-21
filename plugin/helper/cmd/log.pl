# cmd/log.pl: `log --sid S [--stream mod|paths] (--json ROW | --stdin)` (BUILD-PLAN §3.1,
# ROOT-RULINGS F2-6). Owner: WP-core.
# mod (default): O_APPEND writes <= 4 KB per row to <watch>/<sid>.jsonl; paths: to
# <watch>/<sid>/paths.jsonl. A row is the caller's (already enveloped), kept as given after
# a parse check. `--stdin` reads one JSON object per line (blank lines skipped) and appends
# them all in one locked write, so the mod sends one batch per tool call; every line is
# checked before anything is written. A row > 4 KB -> exit 3 `REFUSED: row-too-large`
# (nothing written); a batch over 1 MB -> exit 3 `REFUSED: batch-too-large`.
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
    args::need($opt, 'json') unless $opt->{stdin};
    my $stream = $opt->{stream} // 'mod';
    die "usage: --stream mod|paths\n" unless $stream =~ /^(mod|paths)$/;
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

exit(args::main(\&run, @ARGV));

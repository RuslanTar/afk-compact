# cmd/log.pl: `log --sid S [--stream mod|paths] --json ROW` (BUILD-PLAN §3.1). Owner: WP-core.
# mod (default): one O_APPEND write <= 4 KB to <watch>/<sid>.jsonl; paths: to
# <watch>/<sid>/paths.jsonl. The row is the caller's (already enveloped), kept as
# given after a parse check. Row > 4 KB -> exit 3 `REFUSED: row-too-large`.
use strict;
use warnings;

package cmd_log;

my @STREAM_FLAGS = qw(sid stream json root log-dir disposable-root);

sub run {
    my ($opt) = args::parse(\@_, known => \@STREAM_FLAGS);
    my $sid = args::init_sid($opt);
    args::need($opt, 'json');
    my $stream = $opt->{stream} // 'mod';
    die "usage: --stream mod|paths\n" unless $stream =~ /^(mod|paths)$/;
    my $line = $opt->{json};
    $line =~ s/\n+\z//;
    die "usage: --json must be one line\n" if index($line, "\n") >= 0;
    my $j = eval { jsonc::decode($line) };
    die "usage: --json is not a JSON object\n" unless ref $j eq 'HASH';
    my $bytes = $line;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    if (length($bytes) + 1 > $log::MAX) { args::out('REFUSED: row-too-large'); return 3 }
    my $path = rc::stream_path($stream);
    if (!defined $path) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    util::append($path, $bytes . "\n");
    return 0;
}

exit(args::main(\&run, @ARGV));

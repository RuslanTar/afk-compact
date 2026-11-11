# cmd/cache.pl: `cache [--sid <id>] [--stdin] [--json] [--note-usage]` (0.1.7, D-81). Owner: WP-core.
# Whether the session's prompt cache is warm, for a status line: one plain line (`cache 1h warm
# 42m left ↻3/7`; nothing when unknown) or, with --json, the `<plugin>-cache/v1` object
# (assets/cache-contract.md). --stdin reads the status line's JSON (session_id, prompt_cache,
# transcript_path). Read-only: it writes nothing, and always exits 0 (a usage error says so on
# stderr). The one exception is opt-in (0.1.8, D-83): with --note-usage and --stdin it also records
# the input's rate_limits in the shared usage record (lib/usagerec.pm), and nothing else; the output
# is the same. main.pl loads only the libraries it needs (%SUB_LIBS), so no setup path runs.
use strict;
use warnings;
use utf8;

package cmd_cache;

our $STDIN_MAX = 1024 * 1024;

sub run {
    my @argv = @_;
    my ($opt, $rest) = eval { args::parse(\@argv, known => ['sid'], bools => [qw(stdin json note-usage)]) };
    if (!$opt || @$rest) {
        print STDERR "usage: cache [--sid <id>] [--stdin] [--json] [--note-usage]\n";
        return 0;
    }
    my $in;
    if ($opt->{stdin}) {
        binmode(STDIN, ':raw');
        my $raw = '';
        my $n = read(STDIN, $raw, $STDIN_MAX + 1) // 0;
        $in = eval { jsonc::decode($raw) } if $n > 0 && $n <= $STDIN_MAX;
        eval { usagerec::note(usagerec::from_statusline($in, util::now()), util::now()) } if $opt->{'note-usage'} && ref $in eq 'HASH';
    }
    my $r = eval { cachestate::report(sid => $opt->{sid}, input => $in) };
    $r //= { schema => cachestate::schema(), sid => undef, now => int(util::now()), state => 'unknown', why => 'no-data' };
    if ($opt->{json}) { print STDOUT jsonc::encode_bytes($r) . "\n"; return 0 }
    my $l = eval { cachestate::line($r) } // '';
    args::out($l) if $l ne '';
    return 0;
}

eval { run(@ARGV) };
exit 0;

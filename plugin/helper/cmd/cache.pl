# cmd/cache.pl: `cache [--sid <id>] [--stdin] [--json] [--note-usage]
#   [--bar [--ascii] [--color auto|always|never] [--short] [--left]]` (0.1.7; --bar 0.1.13).
# Whether the session's prompt cache is warm, for a status line: one plain line (`cache 1h warm
# 42m left ↻3/7`; nothing when unknown), with --bar the meter (`██████░░░░░░ 30m`, lib/cachestate.pm
# bar(); nothing when unknown or the TTL is null) or, with --json, the `<plugin>-cache/v1` object
# (assets/cache-contract.md). --stdin reads the status line's JSON (session_id, prompt_cache,
# transcript_path). Read-only: it writes nothing, and always exits 0 (a usage error says so on
# stderr). The one exception is opt-in (0.1.8): with --note-usage and --stdin it also records
# the input's rate_limits in the shared usage record (lib/usagerec.pm), and nothing else; the output
# is the same. main.pl loads only the libraries it needs (%SUB_LIBS), so no setup path runs; --bar
# reads only the environment beyond that (NO_COLOR, TERM, COLUMNS, the locale, WT_SESSION).
use strict;
use warnings;
use utf8;

package cmd_cache;

our $STDIN_MAX = 1024 * 1024;

sub run {
    my @argv = @_;
    my ($opt, $rest) = eval { args::parse(\@argv, known => [qw(sid color)], bools => [qw(stdin json note-usage bar ascii short left)]) };
    if (!$opt || @$rest || (defined $opt->{color} && $opt->{color} !~ /\A(?:auto|always|never)\z/)) {
        print STDERR "usage: cache [--sid <id>] [--stdin] [--json] [--note-usage] [--bar [--ascii] [--color auto|always|never] [--short] [--left]]\n";
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
    $r //= { schema => cachestate::schema(), sid => undef, now => int(util::now()), state => 'unknown', label => 'unknown', why => 'no-data' };
    if ($opt->{json}) { print STDOUT jsonc::encode_bytes($r) . "\n"; return 0 }
    my $l = eval { cachestate::bar($r, $opt->{bar} ? bar_opts($opt) : (plain => 1)) } // '';
    args::out($l) if $l ne '';
    return 0;
}

# bar_opts(opt) -> bar()'s options from the flags and the environment: ASCII with --ascii, a locale
# that names another charset than UTF-8 (LC_ALL, else LC_CTYPE, else LANG; none set reads as UTF-8),
# or an MSYS perl outside Windows Terminal (WT_SESSION); colour by --color, auto = on unless
# NO_COLOR is set and not empty or TERM is dumb; short with --short or a COLUMNS below 60.
sub bar_opts {
    my ($opt) = @_;
    my ($loc) = grep { defined $_ && $_ ne '' } @ENV{qw(LC_ALL LC_CTYPE LANG)};
    my $ascii = $opt->{ascii} || (defined $loc && $loc !~ /utf-?8/i) || ($^O eq 'msys' && !defined $ENV{WT_SESSION}) ? 1 : 0;
    my $c = $opt->{color} // 'auto';
    my $color = $c eq 'always' ? 1 : $c eq 'never' ? 0
              : (defined $ENV{NO_COLOR} && $ENV{NO_COLOR} ne '') || ($ENV{TERM} // '') eq 'dumb' ? 0 : 1;
    my $cols = $ENV{COLUMNS};
    my $short = $opt->{short} || (defined $cols && $cols =~ /\A[0-9]{1,5}\z/ && $cols > 0 && $cols < 60) ? 1 : 0;
    return (ascii => $ascii, color => $color, short => $short, left => $opt->{left} ? 1 : 0);
}

eval { run(@ARGV) };
exit 0;

# cmd/usage.pl: `usage [--sid <id>] [--stdin]` (0.1.8, D-83). Owner: WP-core.
# The shared usage record (lib/usagerec.pm) for the mod. With --stdin and --sid it first adds the
# session's own reading, one JSON object: {"at": epoch seconds, "windows": [{"kind", "pct",
# "resets_at"}]} (source `plugin`); then it prints one JSON line, {"schema", "now", "readings":
# [entry...]}, every entry that still counts (usagerec::kept, a read alone too). It always exits 0 (a usage error says so on stderr, and an empty
# list prints). main.pl loads only the libraries it needs (%SUB_LIBS), so no setup path runs.
use strict;
use warnings;
use utf8;

package cmd_usage;

our $STDIN_MAX = 65536;

sub run {
    my @argv = @_;
    my ($opt, $rest) = eval { args::parse(\@argv, known => ['sid'], bools => ['stdin']) };
    if (!$opt || @$rest) {
        print STDERR "usage: usage [--sid <id>] [--stdin]\n";
        return 0;
    }
    my $now = util::now();
    my $all;
    if ($opt->{stdin}) {
        binmode(STDIN, ':raw');
        my $raw = '';
        my $n = read(STDIN, $raw, $STDIN_MAX + 1) // 0;
        my $in = $n > 0 && $n <= $STDIN_MAX ? eval { jsonc::decode($raw) } : undef;
        my $s8 = usagerec::sid8($opt->{sid});
        if (defined $s8 && ref $in eq 'HASH' && ref $in->{windows} eq 'ARRAY') {
            my $at = $in->{at};
            my @e = map { ref $_ eq 'HASH' ? { kind => $_->{kind}, pct => $_->{pct}, resets_at => $_->{resets_at}, at => $at, src => 'plugin', sid8 => $s8 } : () }
                    @{ $in->{windows} };
            $all = eval { usagerec::note(\@e, $now) };
        }
    }
    $all //= eval { usagerec::kept(usagerec::read_all(), $now) } // [];
    print STDOUT jsonc::encode_bytes({ schema => usagerec::schema(), now => int($now), readings => $all }) . "\n";
    return 0;
}

eval { run(@ARGV) };
exit 0;

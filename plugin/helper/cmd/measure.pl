# cmd/measure.pl: two forms (BUILD-PLAN §2 note). Owner: WP-core.
#   measure --sid S --compact [--cwd DIR] [--nonce N] -> the re-measure block <= 3,000 B (MOD-SPEC §2.6)
#   measure <handoff> [...]                           -> lib/skills/measure_handoff (WP-skills)
use strict;
use warnings;
use utf8;

package cmd_measure;

sub run {
    my ($opt, $rest) = args::parse(\@_, bools => ['compact'],
                                   known => [qw(sid cwd nonce root log-dir queue-cmd disposable-root)]);
    if ($opt->{compact}) {
        my $sid = args::init_sid($opt);
        die "usage: --nonce is 8 lowercase hex\n" if defined $opt->{nonce} && !nonce::valid($opt->{nonce});
        args::out(measure::compact($sid, $opt->{cwd} // do { require Cwd; Cwd::getcwd() }, $opt->{nonce}));
        return 0;
    }
    die "usage: measure --sid S --compact | measure <handoff>\n" unless @$rest == 1;
    rc::init(sid => $opt->{sid}, writer => 'helper', flags => settings::flags_from($opt));
    require "skills/measure_handoff.pm";
    my @lines = skills::measure_handoff::run($rest->[0], rc::settings());
    @lines = @{ $lines[0] } if @lines == 1 && ref $lines[0] eq 'ARRAY';    # the seam may return an array ref
    args::out(@lines);
    return 0;
}

exit(args::main(\&run, @ARGV));

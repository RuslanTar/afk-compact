# cmd/measure.pl: two forms (BUILD-PLAN §2 note). Owner: WP-core.
#   measure --sid S --compact [--cwd DIR] [--nonce N] [--copy FILE [--transcript FILE]]
#                                                     -> the re-measure block <= 3,000 B (MOD-SPEC §2.6)
#   measure --sid S --compact --brief [--cwd DIR]     -> one line <= 600 B (ID-3 `[idle-return]`)
#   measure <handoff> [...]                           -> lib/skills/measure_handoff (WP-skills)
# --copy (AP-5): the saved copy of this compaction's summary; its approvals are checked against this
# session's transcript (--transcript, else <config dir>/projects/<slug of the cwd>/<sid>.jsonl) and
# printed as `Approvals (checked)` lines; a copy that cannot be read yet prints
# `Approvals: not checked (copy pending)`. Without --copy the block has no approvals line, so the
# summary's approvals stay context. A leading `~/` in either path is the home folder (the mod passes
# the saved copy as `save-copy` printed it).
use strict;
use warnings;
use utf8;

package cmd_measure;

sub run {
    my ($opt, $rest) = args::parse(\@_, bools => ['compact', 'brief'],
                                   known => [qw(sid cwd nonce root log-dir queue-cmd disposable-root copy transcript)]);
    if ($opt->{compact}) {
        my $sid = args::init_sid($opt);
        die "usage: --nonce is 8 lowercase hex\n" if defined $opt->{nonce} && !nonce::valid($opt->{nonce});
        my $cwd = $opt->{cwd} // do { require Cwd; Cwd::getcwd() };
        if ($opt->{brief}) {
            die "usage: --brief takes no --copy\n" if defined $opt->{copy};
            args::out(measure::brief($sid, $cwd));
            return 0;
        }
        my %o;
        $o{approvals} = _approvals($sid, $cwd, util::expand_tilde($opt->{copy}), util::expand_tilde($opt->{transcript})) if defined $opt->{copy};
        args::out(measure::compact($sid, $cwd, $opt->{nonce}, %o));
        return 0;
    }
    die "usage: --copy and --brief need --compact\n" if defined $opt->{copy} || $opt->{brief};
    die "usage: measure --sid S --compact | measure <handoff>\n" unless @$rest == 1;
    rc::init(sid => $opt->{sid}, writer => 'helper', flags => settings::flags_from($opt));
    require "skills/measure_handoff.pm";
    my @lines = skills::measure_handoff::run($rest->[0], rc::settings(), sid => $opt->{sid});
    @lines = @{ $lines[0] } if @lines == 1 && ref $lines[0] eq 'ARRAY';    # the seam may return an array ref
    args::out(@lines);
    return 0;
}

# AP-5: the summary's approvals, checked in memory; one content-free approvals_carry row.
sub _approvals {
    my ($sid, $cwd, $copy, $transcript) = @_;
    my $raw = (-f $copy && -r _) ? util::read_file($copy, 1024 * 1024) : undef;
    return ['Approvals: not checked (copy pending)'] unless defined $raw;
    require "skills/approvals.pm";
    my $tp = (defined $transcript && $transcript ne '') ? $transcript : skills::approvals::transcript_path(undef, $sid, $cwd);
    my ($lines, $row) = eval { skills::approvals::summary_lines(util::text($raw), $tp) };
    return ['Approvals: not checked (spec)'] unless $lines;
    rc::emit('approvals_carry', [map { ($_ => $row->{$_}) } sort keys %$row]) if $row;
    return $lines;
}

exit(args::main(\&run, @ARGV));

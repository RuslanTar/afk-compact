# cmd/measure.pl: two forms.
#   measure --sid S --compact [--cwd DIR] [--nonce N] [--copy FILE] [--transcript FILE] [--budget-ms MS]
#                                                     -> the re-measure block <= 3,000 B
#   measure --sid S --compact --brief [--cwd DIR]     -> one line <= 600 B (`[idle-return]`)
#   measure <handoff> [...]                           -> lib/skills/measure_handoff (skill side)
# --copy: the saved copy of this compaction's summary; its approvals are checked against this
# session's transcript (--transcript, else <config dir>/projects/<slug of the cwd>/<sid>.jsonl) and
# printed as `Approvals (checked)` lines; a copy that cannot be read yet prints
# `Approvals: not checked (copy pending)`. Without --copy the block has no approvals line, so the
# summary's approvals stay context. The same transcript gives this session's GSD and Active driver
# lines (lib/gsd.pm). A leading `~/` in either path is the home folder (the mod passes the saved
# copy as `save-copy` printed it).
use strict;
use warnings;
use utf8;

package cmd_measure;

# --budget-ms: the whole call's budget from its start (git <= 2 s, this session's GSD scan and the
# queue step run in sequence); the mod passes it for the delivery-time re-measure it kills at 3 s
# (resume.ts REMEASURE_MS). Without it measure::compact keeps its own budget (7 s).
sub run {
    my $t0 = util::clock_ms();
    my ($opt, $rest) = args::parse(\@_, bools => ['compact', 'brief'],
                                   known => [qw(sid cwd nonce root log-dir queue-cmd disposable-root copy transcript budget-ms)]);
    if ($opt->{compact}) {
        my $sid = args::init_sid($opt);
        die "usage: --nonce is 8 lowercase hex\n" if defined $opt->{nonce} && !nonce::valid($opt->{nonce});
        die "usage: --budget-ms is a number of milliseconds\n" if defined $opt->{'budget-ms'} && $opt->{'budget-ms'} !~ /\A[1-9][0-9]{0,5}\z/;
        my $cwd = $opt->{cwd} // do { require Cwd; Cwd::getcwd() };
        if ($opt->{brief}) {
            die "usage: --brief takes no --copy\n" if defined $opt->{copy};
            args::out(measure::brief($sid, $cwd));
            return 0;
        }
        my %o;
        $o{transcript} = util::expand_tilde($opt->{transcript}) if defined $opt->{transcript} && $opt->{transcript} ne '';
        $o{approvals} = _approvals($sid, $cwd, util::expand_tilde($opt->{copy}), $o{transcript}) if defined $opt->{copy};
        $o{budget_ms} = $opt->{'budget-ms'} - (util::clock_ms() - $t0) if defined $opt->{'budget-ms'};
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

# The summary's approvals, checked in memory; one content-free approvals_carry row.
sub _approvals {
    my ($sid, $cwd, $copy, $transcript) = @_;
    my $raw = (-f $copy && -r _) ? util::read_file($copy, 1024 * 1024) : undef;
    return ['Approvals: not checked (copy pending)'] unless defined $raw;
    require "skills/approvals.pm";
    my $tp = (defined $transcript && $transcript ne '') ? $transcript : skills::approvals::transcript_path(undef, $sid, $cwd);
    my ($lines, $row) = eval { skills::approvals::summary_lines(util::text($raw), $tp, $cwd, $sid) };
    return ['Approvals: not checked (spec)'] unless $lines;
    rc::emit('approvals_carry', [map { ($_ => $row->{$_}) } sort keys %$row]) if $row;
    return $lines;
}

exit(args::main(\&run, @ARGV));

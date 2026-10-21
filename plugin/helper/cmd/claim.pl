# cmd/claim.pl: `claim --sid S --nonce N --channel sessionstart|prompt.context|prompt.submit`
# (MOD-SPEC §3.4). Exclusive create of <watch>/<sid>/resume-claimed/<nonce> (content =
# channel) -> `CLAIMED`, or `TAKEN <channel>`. Row `resume_inject` on CLAIMED. Owner: WP-core.
use strict;
use warnings;

package cmd_claim;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid nonce channel root log-dir)]);
    my $sid = args::init_sid($opt);
    args::need($opt, qw(nonce channel));
    die "usage: --nonce is 8 lowercase hex\n" unless nonce::valid($opt->{nonce});
    die "usage: --channel sessionstart|prompt.context|prompt.submit\n" unless $resumeblock::CHANNELS{ $opt->{channel} };
    my ($r, $who) = resumeblock::claim($sid, $opt->{nonce}, $opt->{channel});
    if ($r eq 'REFUSED') { args::out("REFUSED: $who"); return 3 }
    args::out($r eq 'CLAIMED' ? 'CLAIMED' : "TAKEN $who");
    return 0;
}

exit(args::main(\&run, @ARGV));

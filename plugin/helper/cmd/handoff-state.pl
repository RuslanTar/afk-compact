# cmd/handoff-state.pl: `handoff-state --sid S --ht H` (D-18 B8; BUILD-PLAN §3.1). Owner:
# WP-core. One line, read-only:
#   none                                          no stage bound to this ht
#   staged <stage> draft=<0|1> finish=<command>   begin bound a stage; draft=1 when its
#                                                 body.md has text; <command> is the literal
#                                                 publish command for it (no session id)
#   published <path>                              publish wrote the handoff of this ht
#   superseded <nonce>                            a native compaction ran during the turn
#                                                 and nothing was staged
use strict;
use warnings;

package cmd_handoff_state;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid ht root log-dir)]);
    my $sid = args::init_sid($opt);
    args::need($opt, 'ht');
    die "usage: --ht is 8 lowercase hex\n" unless handoff_turn::valid_ht($opt->{ht});
    my $d = rc::sid_dir();
    if (!defined $d) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    my $s = handoff_turn::state($d, $opt->{ht});
    if ($s->{state} eq 'published') { args::out("published $s->{path}") }
    elsif ($s->{state} eq 'staged') { args::out("staged $s->{stage} draft=$s->{draft} finish=" . ($s->{finish} // 'none')) }
    elsif ($s->{state} eq 'superseded') { args::out("superseded $s->{nonce}") }
    else { args::out('none') }
    return 0;
}

exit(args::main(\&run, @ARGV));

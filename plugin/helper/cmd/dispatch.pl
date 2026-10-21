# cmd/dispatch.pl: write a dispatch record (MOD-SPEC §2.3; BUILD-PLAN §3.1, §3.4). Owner: WP-core.
# dispatch --sid S --nonce N --actor main|<agentId> --trigger T --channel mod-hook|mod-self|classic
#   --resume-pref P --tags a,b --midturn true|false --instr-sha8 H --instr-bytes B
#   --cc-version V --load-id L [--handoff-ht H]
# -> `ok`; an existing record -> exit 3 `REFUSED: nonce-exists`. Row `dispatch`.
# --handoff-ht (D-18 B3): the handoff turn this dispatch follows or interrupts.
use strict;
use warnings;

package cmd_dispatch;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid nonce actor trigger channel resume-pref tags midturn instr-sha8
                                              instr-bytes cc-version load-id handoff-ht root log-dir)]);
    my $sid = args::init_sid($opt);
    args::need($opt, qw(nonce actor trigger channel));
    die "usage: --nonce is 8 lowercase hex\n" unless nonce::valid($opt->{nonce});
    die "usage: --channel mod-hook|mod-self|classic\n" unless $dispatch::CHANNELS{ $opt->{channel} };
    die "usage: --actor main|unknown|<agentId>\n" unless $opt->{actor} =~ /^[A-Za-z0-9._-]{1,64}$/;
    my $pref = $opt->{'resume-pref'} // ($opt->{actor} eq 'main' ? 'prompt.context' : 'none');
    die "usage: --resume-pref prompt.context|sessionstart|prompt.submit|none\n" unless $dispatch::PREFS{$pref};
    my @tags = grep { $_ ne '' } split /,/, ($opt->{tags} // '');
    for my $t (@tags) { die "usage: --tags from midturn,auto,chain,measured,handoff\n" unless $dispatch::TAGS{$t} }
    die "usage: --handoff-ht is 8 lowercase hex\n" if defined $opt->{'handoff-ht'} && !handoff_turn::valid_ht($opt->{'handoff-ht'});
    my $mid = $opt->{midturn} // 'false';
    die "usage: --midturn true|false\n" unless $mid =~ /^(true|false)$/;
    die "usage: --instr-sha8 is 8 hex\n" if defined $opt->{'instr-sha8'} && $opt->{'instr-sha8'} !~ /^[0-9a-f]{8}$/;
    die "usage: --instr-bytes is a number\n" if defined $opt->{'instr-bytes'} && $opt->{'instr-bytes'} !~ /^\d+$/;
    my $trigger = $opt->{trigger};
    my $unknown_trigger = !$dispatch::TRIGGERS{$trigger};
    my $w = rc::watch();
    if (!defined $w) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    my $c = rc::claude();
    my $rec = dispatch::record(
        nonce => $opt->{nonce}, session_id => $sid, actor => $opt->{actor}, trigger => ($unknown_trigger ? 'unknown' : $trigger),
        channel => $opt->{channel}, resume_pref => $pref, midturn => ($mid eq 'true'), tags => \@tags,
        instructions_sha8 => $opt->{'instr-sha8'}, instructions_bytes => $opt->{'instr-bytes'},
        cc_version => $opt->{'cc-version'}, load_id => $opt->{'load-id'}, pid => $c->{pid}, pid_lstart => $c->{lstart},
        handoff_ht => $opt->{'handoff-ht'},
    );
    my $ok = dispatch::write($w, $sid, $rec);
    if (!$ok) { args::out('REFUSED: nonce-exists'); return 3 }
    my %h = @$rec;
    rc::emit('dispatch', [nonce => $h{nonce}, trigger => $h{trigger}, agent_id => $h{agent_id}, compaction_seq => undef,
                          channel => $h{channel}, resume_pref => $h{resume_pref}, midturn => $h{midturn}, tags => $h{tags},
                          instructions_bytes => $h{instructions_bytes},
                          (defined $h{handoff_ht} ? (handoff_ht => $h{handoff_ht}) : ())],
             actor => ($h{actor} eq 'main' ? 'main' : $h{actor}));
    args::out('ok');
    return 0;
}

exit(args::main(\&run, @ARGV));

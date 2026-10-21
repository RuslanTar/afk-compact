# cmd/save-copy.pl: `save-copy --sid S --nonce N|- --from FILE --writer mod|postcompact-fallback
# --scope main|sub|unknown [--agent ID] [--tokens B,A] [--cwd DIR] [--transcript PATH]`
# (MOD-SPEC §2.6, §5.3; BUILD-PLAN §3.1). Owner: WP-core.
# line 1 `VERDICT <v> marker_line=<n|-> sentinel_from_end=<k|->`; line 2 one of
# `Saved copy: <path>` · `EXISTS: <path> sha-match` · `EXISTS: <path> sha-differs` ·
# `REFUSED: <reason>` (exit 3).
use strict;
use warnings;

package cmd_save_copy;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid nonce from writer scope agent tokens cwd transcript root log-dir)]);
    my $sid = args::init_sid($opt);
    args::need($opt, qw(nonce from writer scope));
    my $nonce = $opt->{nonce} eq '-' ? undef : $opt->{nonce};
    die "usage: --nonce is 8 lowercase hex or -\n" if defined $nonce && !nonce::valid($nonce);
    die "usage: --writer mod|postcompact-fallback\n" unless $opt->{writer} =~ /^(mod|postcompact-fallback)$/;
    die "usage: --scope main|sub|unknown\n" unless $opt->{scope} =~ /^(main|sub|unknown)$/;
    my $tokens;
    if (defined $opt->{tokens}) {
        die "usage: --tokens B,A\n" unless $opt->{tokens} =~ /^(\d*),(\d*)$/;
        $tokens = [length $1 ? 0 + $1 : undef, length $2 ? 0 + $2 : undef];
    }
    my $text = util::read_file($opt->{from});
    die "usage: --from cannot be read\n" unless defined $text;
    my $w = rc::watch();
    my $rec = defined $nonce && defined $w ? dispatch::read($w, $sid, $nonce) : undef;
    my $agent = $opt->{agent} // ($rec ? $rec->{agent_id} : undef);
    my $cwd = $opt->{cwd} // do { require Cwd; Cwd::getcwd() };
    my $s = detect::scan($text);
    my %vc = (dispatch_nonce => $nonce);
    $vc{marker_has_record} = (defined $s->{nonce} && defined $w && -e dispatch::path($w, $sid, $s->{nonce})) ? 1 : 0 if defined $s->{nonce};
    my $r = copies::save(sid => $sid, text => $text, scan => $s, nonce => $nonce, writer => $opt->{writer}, scope => $opt->{scope},
                         agent => $agent, tokens => $tokens, cwd => $cwd, transcript => $opt->{transcript},
                         dispatch => $rec, channel => ($rec ? $rec->{channel} : 'none'),
                         seat_state => ($rec ? (postcompact::seat_state($rec, $opt->{transcript}))[0] : 'none'),
                         verdict_ctx => \%vc);
    args::out($r->{line1}, $r->{line2});
    return $r->{exit};
}

exit(args::main(\&run, @ARGV));

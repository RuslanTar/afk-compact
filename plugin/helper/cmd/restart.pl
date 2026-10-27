# cmd/restart.pl: restart on update (SESSION-RESTART §2, §3.4, §4.1, §5), the helper calls of the
# mod. One JSON line per call, exit 0; a usage error exits 64. Owner: WP-core.
#   restart gate --sid S --route fg|bg [--launch DIR | --job-dir DIR] --from V --to V
#                [--model M] --since MS [--now-ms MS]
#       -> {ok, why, setting, route, mode, effort, job_short, token, types}
#   restart arm --sid S --route fg|bg --nonce N --from V --to V --continue 0|1 --mode X
#               [--effort E] [--model M] [--launch DIR | --job-dir DIR] [--load-id L] [--now-ms MS]
#       -> {ok, why, token}
#   restart set --sid S --nonce N --state X [--exiting-at MS] [--launch DIR] [--now-ms MS]
#       -> {ok, l, c}
#   restart claim --sid S --load-id L [--launch DIR] [--bg] [--now-ms MS]
#       -> {claimed, why, route, from, to, continue, nonce, at, refused}
#   restart respawn --sid S --short J --nonce N --to V [--wait-ms MS (test mode)]
#       -> {ok, pid, why}
#   restart respawn-cancel --sid S --nonce N
#       -> {ok, killed}
# Paths come from the mod's literal env reads (the launch folder, the job folder) and are
# checked here; replies and rows carry none of them.
use strict;
use warnings;
use utf8;

package cmd_restart;

my %SUBS = map { $_ => 1 } qw(gate arm set claim respawn respawn-cancel);

sub _str { my ($v) = @_; return defined $v && !ref $v && $v ne '' ? $v : undef }

sub run {
    my ($opt, $rest) = args::parse(\@_, known => [qw(sid root log-dir route launch job-dir from to model since now-ms nonce
                                                     continue mode effort load-id state exiting-at short wait-ms)],
                                   bools => [qw(bg)]);
    my $sub = $rest->[0] // '';
    die "usage: restart gate|arm|set|claim|respawn|respawn-cancel --sid S\n" unless $SUBS{$sub};
    my $sid = args::init_sid($opt);
    my $d = rc::sid_dir();
    my $now = restart::is_ms($opt->{'now-ms'}) ? 0 + $opt->{'now-ms'} : restart::now_ms();
    my $route = ($opt->{route} // '') eq 'bg' ? 'bg' : 'fg';
    my $o;
    if ($sub eq 'gate') {
        my $r = restart::gate(sid => $sid, sid_dir => $d, setting => rc::val('restart_on_update'), route => $route,
                              launch => _str($opt->{launch}), job_dir => _str($opt->{'job-dir'}), from => $opt->{from},
                              to => $opt->{to}, model => $opt->{model} // '', since => $opt->{since}, now => $now);
        $o = jsonc::obj(ok => jsonc::bool($r->{ok}), why => $r->{why}, setting => $r->{setting}, route => $r->{route},
                        mode => $r->{mode}, effort => $r->{effort}, job_short => $r->{job_short}, token => $r->{token},
                        types => $r->{types});
    } elsif ($sub eq 'arm') {
        my $job = _str($opt->{'job-dir'});
        my $r = restart::arm(sid => $sid, sid_dir => $d, route => $route, nonce => $opt->{nonce}, from => $opt->{from},
                             to => $opt->{to}, continue => (($opt->{continue} // '0') eq '1'), mode => $opt->{mode},
                             effort => $opt->{effort} // '', model => $opt->{model} // '', launch => _str($opt->{launch}),
                             job_short => (defined $job ? util::basename($job =~ s{(?<=.)/+\z}{}r) : undef),
                             load_id => $opt->{'load-id'}, now => $now);
        $o = jsonc::obj(ok => jsonc::bool($r->{ok}), why => $r->{why}, token => $r->{token});
    } elsif ($sub eq 'set') {
        my $r = restart::set_state(sid => $sid, sid_dir => $d, nonce => $opt->{nonce}, state => $opt->{state}, now => $now,
                                   exiting_at => $opt->{'exiting-at'}, launch => _str($opt->{launch}));
        $o = jsonc::obj(ok => jsonc::bool($r->{ok}), l => $r->{l}, c => $r->{c});
    } elsif ($sub eq 'claim') {
        my $r = restart::claim(sid => $sid, sid_dir => $d, load_id => $opt->{'load-id'}, launch => _str($opt->{launch}),
                               bg => ($opt->{bg} ? 1 : 0), now => $now);
        $o = jsonc::obj(claimed => jsonc::bool($r->{claimed}), why => $r->{why}, route => $r->{route}, from => $r->{from},
                        to => $r->{to}, continue => jsonc::bool($r->{continue}), nonce => $r->{nonce}, at => $r->{at},
                        refused => [map { jsonc::obj(reason => $_->{reason}, at => $_->{at}) } @{ $r->{refused} }]);
    } elsif ($sub eq 'respawn') {
        # The row the detached helper may write needs the envelope's claude pid now: the walk
        # from the grandchild (reparented, in its own session) would find nothing.
        rc::claude();
        my $r = restart::respawn(sid => $sid, sid_dir => $d, short => $opt->{short}, nonce => $opt->{nonce},
                                 to => (restart::is_ver($opt->{to}) ? $opt->{to} : undef), wait_ms => $opt->{'wait-ms'});
        $o = jsonc::obj(ok => jsonc::bool($r->{ok}), pid => $r->{pid}, why => $r->{why});
    } else {
        my $r = restart::respawn_cancel($d, $opt->{nonce} // '');
        $o = jsonc::obj(ok => jsonc::bool($r->{ok}), killed => jsonc::bool($r->{killed}));
    }
    args::out(jsonc::encode($o));
    return 0;
}

exit(args::main(\&run, @ARGV));

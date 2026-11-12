# cmd/trial-measure.pl: `trial-measure --sid S --cwd DIR [--cc-version V] [--budget-ms N]` ->
# one JSON line: the local shadow trial's state for this session and, when it runs here, the
# texts the two shadow forks need. It writes nothing in
# the trial folder, the handoff buckets or the session's queue state (only the helper's usual session
# bookkeeping): the queue tool's list is read quiet. The skip-list is tested first, after one git call.
#   {"state":"absent"}                       no trial config: the mod does nothing at all
#   {"state":"off"|"bad","why":W}            a config that is off, ended or not valid: nothing
#   {"state":"on","skip":K,"why":W}          on, but not for this session (K: not-owner-config,
#                                            cc-version, repo-skipped): one skip record per moment
#   {"state":"on","skip":null,"m3","native_tail","facts":{…},"old":{…},"native":{…}}
# `old.status` is `ok` (with the filled skill and template) or `no-old-skill`; `native.status` is
# `ok` (with the head and tail for this version, arm and transcript flag) or `no-native-prompt`.
use strict;
use warnings;
use utf8;
require "trial.pm";

package cmd_trial_measure;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid cwd cc-version budget-ms root log-dir)]);
    my $sid = args::init_sid($opt);
    my $cwd = $opt->{cwd} // do { require Cwd; Cwd::getcwd() };
    my $budget = defined $opt->{'budget-ms'} && $opt->{'budget-ms'} =~ /^\d{1,6}$/ ? 0 + $opt->{'budget-ms'} : 2500;
    my $l = trial::load();
    if ($l->{state} ne 'on') {
        args::out(jsonc::encode({ state => $l->{state}, why => $l->{why} }));
        return 0;
    }
    my $cfg = $l->{cfg};
    my $on = sub { args::out(jsonc::encode({ state => 'on', %{ $_[0] } })); return 0 };
    if (defined(my $why = trial::owner_skip($cfg))) { return $on->({ skip => 'not-owner-config', why => $why }) }
    my $ver = $opt->{'cc-version'};
    return $on->({ skip => 'cc-version', why => (defined $ver ? 'unlisted' : 'unknown') })
        unless defined $ver && grep { $_ eq $ver } @{ $cfg->{cc_versions} };
    my $pl = trial::place($cwd, $budget);
    return $on->({ skip => 'repo-skipped', why => 'skip_repos' }) if trial::skipped_repo($cfg, $pl->{repo}, $pl->{repo_name});
    my $f = trial::facts($sid, $cwd, $cfg, $budget, $pl);
    my $old = trial::old_skill($cfg, rc::val('queue_cmd'));
    my $native = trial::native($cfg, $ver, $sid);
    my %fx = map { ($_ => $f->{$_}) } qw(text repo ticket worktree branch head dirty old_chain_flagged);
    $fx{measured_at} = util::iso(util::now());
    return $on->({
        skip => undef, m3 => jsonc::bool($cfg->{m3}), native_tail => jsonc::bool($cfg->{native_tail}),
        facts => \%fx, old => $old,
        native => { %$native, map { ($_ => jsonc::bool($native->{$_})) } grep { defined $native->{$_} } qw(cache_prefix_flag precompact_hooks) },
    });
}

exit(args::main(\&run, @ARGV));

# cmd/ident.pl: `ident --sid S` -> {"pid":N,"pid_lstart":"…","execpath_version":"…"|null,
# "watch":"<abs dir>"|null} (BUILD-PLAN §3.1, E-18; the mod caches it at session.start).
# `watch` is the effective log folder after the unsafe-root checks (MOD-SPEC §1.2): log_dir,
# else <root>/.watch when log_dir is unsafe, else null (refused). The mod writes its files
# there, so neither side writes under a refused root. Owner: WP-core.
# SESSION-RESTART: `restart` is the restart_on_update setting (off, shadow or on; settings file
# only), and `restart_reports` the background restarts that failed after the old process ended
# (§2.3: `[{short, to, code}]`, each marked reported here, so one load reports it once); the scan
# runs only while the setting is not off.
use strict;
use warnings;
use utf8;

package cmd_ident;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid root log-dir)]);
    my $sid = args::init_sid($opt);
    my $c = rc::claude();
    my $restart = rc::val('restart_on_update') // 'off';
    my @rep = $restart eq 'off' ? () : eval { restart::report_failed(rc::watch(), restart::now_ms()) };
    args::out(jsonc::encode(jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, execpath_version => rc::exec_version(),
                                       watch => rc::watch(), restart => $restart,
                                       restart_reports => [map { jsonc::obj(short => $_->{short}, to => $_->{to}, code => $_->{code}) } @rep])));
    return 0;
}

exit(args::main(\&run, @ARGV));

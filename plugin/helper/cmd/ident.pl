# cmd/ident.pl: `ident --sid S` -> {"pid":N,"pid_lstart":"…","execpath_version":"…"|null,
# "watch":"<abs dir>"|null} (BUILD-PLAN §3.1, E-18; the mod caches it at session.start).
# `watch` is the effective log folder after the unsafe-root checks (MOD-SPEC §1.2): log_dir,
# else <root>/.watch when log_dir is unsafe, else null (refused). The mod writes its files
# there, so neither side writes under a refused root. Owner: WP-core.
use strict;
use warnings;
use utf8;

package cmd_ident;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid root log-dir)]);
    my $sid = args::init_sid($opt);
    my $c = rc::claude();
    args::out(jsonc::encode(jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, execpath_version => rc::exec_version(),
                                       watch => rc::watch())));
    return 0;
}

exit(args::main(\&run, @ARGV));

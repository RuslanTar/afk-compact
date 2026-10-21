# cmd/ident.pl: `ident --sid S` -> {"pid":N,"pid_lstart":"…","execpath_version":"…"|null}
# (BUILD-PLAN §3.1, E-18; the mod caches it at session.start). Owner: WP-core.
use strict;
use warnings;

package cmd_ident;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid root log-dir)]);
    my $sid = args::init_sid($opt);
    my $c = rc::claude();
    args::out(jsonc::encode(jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, execpath_version => rc::exec_version())));
    return 0;
}

exit(args::main(\&run, @ARGV));

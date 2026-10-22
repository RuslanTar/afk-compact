# cmd/notice.pl: the watcher's first-run notice (W-BETA A; WATCHER-SPEC §8 item 8). Owner: WP-core.
#   notice claim --id ID [--sid S]
#     -> `show` when this call created <watch>/notice/<ID>.shown (exclusive create, 0600 in a
#        0700 folder), `seen` when it was there already; `off` (no marker) while watcher = off,
#        so the notice still shows once the watcher is turned on. The mod shows the toast only
#        on `show`. The marker is per install (per config dir); the id carries the version.
#   notice text [--id ID]
#     -> the fixed text (spec `notice` object, {{plugin}} filled, at most 200 characters)
# No row, no content. Exit 0; 64 usage; 3 `REFUSED: no-watch` without a log folder.
use strict;
use warnings;
use utf8;

package cmd_notice;

sub run {
    my $verb = shift // '';
    my ($opt) = args::parse(\@_, known => [qw(id sid root log-dir)]);
    die "usage: notice claim --id ID | notice text [--id ID]\n" unless $verb =~ /\A(?:claim|text)\z/;
    die "usage: --sid is not a session id\n" if defined $opt->{sid} && !args::valid_sid($opt->{sid});
    rc::init(sid => $opt->{sid} // 'unknown', writer => 'helper', flags => settings::flags_from($opt));
    my $n = notice::spec();
    if ($verb eq 'text') {
        die "usage: --id is lowercase letters, digits and -\n" if defined $opt->{id} && !notice::valid_id($opt->{id});
        args::out($n->{text});
        return 0;
    }
    args::need($opt, 'id');
    die "usage: --id is lowercase letters, digits and -\n" unless notice::valid_id($opt->{id});
    my $w = lc(rc::val('watcher') // 'shadow');
    $w =~ s/^\s+|\s+$//g;
    if ($w eq 'off') { args::out('off'); return 0 }
    my $watch = rc::watch();
    if (!defined $watch) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    my $r = notice::claim($watch, $opt->{id});
    if (!defined $r) { args::out('REFUSED: marker-unwritable'); return 3 }
    args::out($r);
    return 0;
}

exit(args::main(\&run, @ARGV));

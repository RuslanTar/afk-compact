# cmd/prev-copy.pl: `prev-copy --sid S --actor main [--cwd DIR]` -> the ~-abbreviated
# absolute path of this session's newest main copy by frontmatter `date`, or `none`.
# Owner: WP-core.
use strict;
use warnings;

package cmd_prev_copy;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid actor cwd root log-dir)]);
    my $sid = args::init_sid($opt);
    my $actor = $opt->{actor} // 'main';
    die "usage: --actor main\n" unless $actor eq 'main';
    my $bk = bucket::resolve($sid, $opt->{cwd} // do { require Cwd; Cwd::getcwd() });
    my $p = copies::prev_copy($sid, $bk->{path});
    args::out(defined $p ? util::abbrev($p) : 'none');
    return 0;
}

exit(args::main(\&run, @ARGV));

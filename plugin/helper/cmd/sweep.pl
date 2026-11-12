# cmd/sweep.pl: `sweep --sid S --nonce N [--transcript PATH] [--cwd DIR]`.
# One line per file `<status>\t<origin>\t<copy or ->\t<bytes>\t<sha8>`,
# then `TOTAL …`, then `WARN quota <bucket> <mb>` when over.
use strict;
use warnings;
use utf8;

package cmd_sweep;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid nonce transcript cwd root log-dir disposable-root quota-mb)]);
    my $sid = args::init_sid($opt);
    args::need($opt, 'nonce');
    die "usage: --nonce is 8 lowercase hex\n" unless nonce::valid($opt->{nonce});
    my $cwd = $opt->{cwd} // do { require Cwd; Cwd::getcwd() };
    my $bk = bucket::resolve($sid, $cwd);
    my $id6 = substr($opt->{nonce}, 0, 6);
    my $copy = copies::find($bk->{path}, $id6);
    (my $stem = util::basename($copy // '')) =~ s/\.md$//;
    $stem = util::file_stamp(util::now()) . '_' . substr($sid, 0, 8) . "-$id6" if $stem eq '';
    my $r = sweep::run(sid => $sid, id6 => $id6, stem => $stem, transcript => $opt->{transcript},
                       budget_ms => 8000, bucket => $bk->{path}, nonce => $opt->{nonce});
    args::out(@{ $r->{lines} });
    return $r->{exit};
}

exit(args::main(\&run, @ARGV));

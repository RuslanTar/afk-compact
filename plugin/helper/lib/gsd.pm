package gsd;
# lib/gsd.pm: read-only GSD position of the session's own worktree (OD-8, S-13).
# Owner: WP-core. Reads <worktree>/.planning/STATE.md only; never writes it.
use strict;
use warnings;
use utf8;

# read(worktree) -> {status: ok|none, path, lines => [<= 8], mtime}
sub read {
    my ($worktree) = @_;
    return { status => 'none' } unless defined $worktree && $worktree ne '';
    my $path = "$worktree/.planning/STATE.md";
    return { status => 'none' } unless -f $path;
    my $raw = util::read_file($path, 256 * 1024);
    return { status => 'none' } unless defined $raw;
    utf8::decode($raw);
    $raw =~ s/\r\n?/\n/g;
    $raw =~ s/\A---\n.*?\n---\n//s;    # frontmatter
    my @lines;
    for my $l (split /\n/, $raw) {
        next unless $l =~ /\S/;
        $l =~ s/\s+$//;
        $l = substr($l, 0, 160) . '…' if length $l > 160;
        push @lines, $l;
        last if @lines >= 8;
    }
    return { status => 'ok', path => $path, lines => \@lines, mtime => (stat $path)[9] };
}

1;

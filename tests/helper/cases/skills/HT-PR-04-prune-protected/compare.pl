#!/usr/bin/perl
# HT-PR-04 test helper (never shipped): calls the staged prune's protected-path compare directly,
# with the identity sub replaced by one that returns no identity, as a native Windows perl (inode 0)
# leaves it, so the text-only fallback is tested without any switch in the plugin.
# usage: compare.pl <plugin dir> <stubs> <root> <entry> [<root> <entry>]...
#   stubs: a comma list, or none: no-ino (no identity, as a native Windows perl), no-alias-text (no
#   macOS join-point text forms, so only the identity tests, the alias probe among them, decide)
# prints one line per pair: `<root> | <entry> | <equals|inside|contains|none>`
use strict;
use warnings;
my ($plugin, $stubs, @pairs) = @ARGV;
die "compare.pl: usage: compare.pl <plugin> <stubs> <root> <entry>...\n" unless defined $stubs && @pairs && @pairs % 2 == 0;
unshift @INC, "$plugin/helper/lib";
require "util.pm";
require "skills/prune.pm";
my %stub = map { ($_ => 1) } split /,/, $stubs;
{
    no warnings 'redefine';
    *skills::prune::_id = sub { undef } if $stub{'no-ino'};
    *skills::prune::_forms_of = sub { $_[0] } if $stub{'no-alias-text'};
}
while (my ($root, $entry) = splice @pairs, 0, 2) {
    my $ri = skills::prune::_info($root, 0) or die "compare.pl: $root: not an absolute path\n";
    my $p = skills::prune::_entry('compare', $entry) or die "compare.pl: $entry: not an absolute path\n";
    my $how = skills::prune::_hit($ri, $p) // 'none';
    print "$root | $entry | $how\n";
}
exit 0;

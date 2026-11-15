#!/usr/bin/perl
# HT-PR-04 test helper (never shipped): the race between prune's protected-roots check and its
# unlinks, with no seam in the plugin. Loads the staged plugin's prune, wraps the MANIFEST lookup
# that --apply makes after the check and before the unlinks so that it then renames folder FROM
# to FROM.moved and puts a link FROM -> TO in its place (a concurrent writer's swap), and runs the
# staged main.pl with the rest of the arguments.
# usage: race.pl <plugin dir> <from> <to> prune [args...]
use strict;
use warnings;
my ($plugin, $from, $to, @argv) = @ARGV;
die "race.pl: usage: race.pl <plugin> <from> <to> <subcommand> [args]\n" unless defined $plugin && defined $to && @argv;
# a test helper must never move a folder outside the case's own temp folder
my $tmp = $ENV{STORE_TEST_RACE_TMP} // '';
die "race.pl: from and to must lie under STORE_TEST_RACE_TMP\n"
    unless $tmp =~ m{\A/.+} && index($from, "$tmp/") == 0 && index($to, "$tmp/") == 0;
unshift @INC, "$plugin/helper/lib";
require "skills/prune.pm";
my $orig = \&skills::prune::_manifests;
my $done = 0;
{
    no warnings 'redefine';
    *skills::prune::_manifests = sub {
        my @r = $orig->(@_);
        if (!$done++) {
            rename($from, "$from.moved") or die "race.pl: rename $from: $!\n";
            symlink($to, $from) or die "race.pl: symlink $from: $!\n";
        }
        return @r;
    };
}
@ARGV = @argv;
my $main = "$plugin/helper/main.pl";
do $main;
die $@ if $@;
exit 70;

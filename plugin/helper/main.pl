#!/usr/bin/perl
# helper/main.pl: entry of the plugin helper, started by bin/<name>-store.
# Owner: WP-core. Phase 0 stub dispatcher (BUILD-PLAN §3.1).
#
# The guard below must stay parsable by perl 5.8: it runs before any other
# `use`, so an old perl that reaches this file still takes the fallback
# (hook: drain stdin, print nothing, exit 0; anything else: refuse, exit 3).
BEGIN {
    if ($] < 5.028) {
        if (@ARGV && $ARGV[0] eq 'hook') {
            local $/;
            my $drain = <STDIN>;
            exit 0;
        }
        print "REFUSED: helper-runtime\n";
        exit 3;
    }
}

use strict;
use warnings;
use File::Basename ();
use Cwd ();
my $HELPER_DIR;
BEGIN { $HELPER_DIR = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
use lib "$HELPER_DIR/lib";

# Subcommands of the §3.1 table. Each one lives in cmd/<sub>.pl.
my %KNOWN = map { $_ => 1 } qw(
    hook ident dispatch prev-copy checkpoint save-copy sweep claim measure log
    reconcile status smoke
    begin stamp evidence publish locate inventory heal-check verify
    restore-evidence stash lane pin receipt
    watch
);

my $sub = shift @ARGV;
if (!defined $sub || !$KNOWN{$sub}) {
    print STDERR "usage: <name>-store <subcommand> [args]\n";
    exit 64;
}

if ($sub eq 'hook') {
    # `hook <Event>` always exits 0 and prints nothing until it is built.
    local $/;
    my $drain = <STDIN>;
    exit 0;
}

my $file = "$HELPER_DIR/cmd/$sub.pl";
if (-f $file) {
    my $ok = do $file;
    if (!defined $ok && $@) {
        print STDERR "$sub: $@";
    }
    exit 70;
}
print STDERR "$sub: not implemented\n";
exit 70;

#!/usr/bin/perl
# helper/main.pl: entry of the plugin helper, started by the launcher in scripts/.
# Owner: WP-core. Dispatches `<subcommand>` to cmd/<subcommand>.pl (BUILD-PLAN §3.1).
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
use utf8;
use File::Basename ();
use Cwd ();
my $HELPER_DIR;
BEGIN { $HELPER_DIR = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
use lib "$HELPER_DIR/lib";

umask 077;
binmode STDOUT;
binmode STDIN;

# Subcommands of the §3.1 table. Each one lives in cmd/<sub>.pl.
my %KNOWN = map { $_ => 1 } qw(
    hook ident dispatch prev-copy checkpoint save-copy sweep claim measure log
    reconcile status smoke handoff-turn handoff-state queue-add
    begin stamp evidence publish locate inventory heal-check verify
    restore-evidence stash lane pin receipt wait project
    watch
);

my $sub = shift @ARGV;
if (!defined $sub || !$KNOWN{$sub}) {
    print STDERR "usage: <subcommand> [args]\n";
    exit 64;
}

my $IS_HOOK = $sub eq 'hook';
if ($IS_HOOK) {
    # Hooks never write stderr, and nothing but our text reaches stdout.
    open(STDERR, '>', '/dev/null');
    $SIG{__WARN__} = sub { };
    $SIG{PIPE} = 'IGNORE';
}

# Core libraries every subcommand may use (BUILD-PLAN §3.6 seams).
for my $lib (qw(util jsonc sha ctx spec settings paths roots log rc identity lock nonce
                git gsd queue bucket frontmatter detect assemble secrets evidence
                dispatch transcript scope sessions sidecar copies measure checkpoint
                sweep reconcile keyset resumeblock args rollup postcompact repomode jobrec handoff_turn)) {
    my $ok = eval { require "$lib.pm"; 1 };
    if (!$ok) {
        if ($IS_HOOK) { local $/; my $d = <STDIN>; exit 0 }
        print STDERR "$sub: cannot load $lib: $@";
        exit 70;
    }
}
ctx::init($HELPER_DIR);

my $file = "$HELPER_DIR/cmd/$sub.pl";
if (!-f $file) {
    if ($IS_HOOK) { local $/; my $d = <STDIN>; exit 0 }
    print STDERR "$sub: not implemented\n";
    exit 70;
}
my $ok = do $file;
if (!defined $ok && $@) {
    exit 0 if $IS_HOOK;
    print STDERR "$sub: $@";
}
exit($IS_HOOK ? 0 : 70);

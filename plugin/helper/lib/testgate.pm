package testgate;
# lib/testgate.pm: the one gate for the helper's test switches (every STORE_TEST_* variable).
#
# Test mode is on only when STORE_TEST_MODE=1 is in the environment AND the plugin copy this file
# runs from is a test stage: its root (two folders above helper/lib, found from this file's own
# real path, never from the environment) holds the marker file $MARK, a regular file (not a link)
# owned by the user running the helper. Only the test stagers write it into their temporary
# copies (tests/helper/run.pl, the watch driver, tools/helper-replies-gen); the plugin as built,
# released and installed never holds it, and the release gates fail when it does (tools/gates,
# test-stage). So an environment prefix alone (`STORE_TEST_MODE=1 STORE_TEST_NOW=...`) turns no
# switch on in a normal run: without the marker every STORE_TEST_* variable is ignored, and
# main.pl names them once on stderr (note_ignored).
#
# A test harness that loads the helper's libraries into its own process (the helper case runner's
# builtins, the watch driver) has no staged root; it sets $testgate::IN_PROCESS = 1 itself, which
# stands in for the marker only (STORE_TEST_MODE=1 is still needed). No environment value can set it.
#
# Every read of a STORE_TEST_* variable in the helper goes through on() (util::test_mode and
# skills::util::test_mode call it). Kept free of other helper libraries and of syntax newer than
# perl 5.8: main.pl loads it before its perl version check.
use strict;
use warnings;

our $MARK = '.store-test-stage';
our $IN_PROCESS;
my $MARKED;

# root() -> the plugin root this file belongs to (<root>/helper/lib/testgate.pm), or undef.
sub root {
    require Cwd;
    require File::Basename;
    my $f = Cwd::abs_path(__FILE__);
    return undef unless defined $f;
    my $d = File::Basename::dirname(File::Basename::dirname(File::Basename::dirname($f)));
    return $d;
}

# marked() -> 1 when the plugin root holds the test-stage marker (a regular file, not a link, owned
# by this user). Read once per process: the root does not move while the helper runs.
sub marked {
    return $MARKED if defined $MARKED;
    my $r = root();
    my @l = defined $r ? lstat("$r/$MARK") : ();
    $MARKED = (@l && -f _ && !-l _ && $l[4] == $<) ? 1 : 0;
    return $MARKED;
}

# on() -> 1 when the test switches count: STORE_TEST_MODE=1 and a test stage (or an in-process harness).
sub on {
    my $m = $ENV{STORE_TEST_MODE};
    return 0 unless defined $m && $m eq '1';
    return 1 if $IN_PROCESS;
    return marked();
}

# ignored() -> the STORE_TEST_* variables set in the environment while on() is 0, sorted.
sub ignored {
    return () if on();
    return sort grep { /\ASTORE_TEST_/ } keys %ENV;
}

# note_ignored(name) -> once per process, when STORE_TEST_MODE=1 is set outside a test stage,
# one stderr line naming the ignored variables (never their values).
my $NOTED;
sub note_ignored {
    my ($name) = @_;
    return if $NOTED++;
    my $m = $ENV{STORE_TEST_MODE};
    return unless defined $m && $m eq '1' && !on();
    print STDERR (defined $name ? "$name: " : '') . 'test switches ignored (not a test stage): ' . join(', ', ignored()) . "\n";
}

1;

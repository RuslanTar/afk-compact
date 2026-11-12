# AT-AN-17: AT-AN-16 when the session ends with no SessionEnd (its
# process gone): the next session's start finishes it across sessions (lib/orphans.pm), and the
# watcher's end pass runs for it there, in its context, as its own SessionEnd would have.
my $case = do {
    local $T::AN_FINISH = 1;
    my $f = __FILE__;
    $f =~ s{AT-AN-17-a01-finish/case\.pl\z}{AT-AN-16-a01-session-end/case.pl} or die "AT-AN-17: path $f\n";
    do $f;
};
die "AT-AN-17: AT-AN-16 did not load: $@\n" unless ref $case eq 'HASH';
$case;

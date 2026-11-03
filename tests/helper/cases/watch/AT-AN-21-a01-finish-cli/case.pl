# AT-AN-21 (0.1.4 W-7): AT-AN-17 with the session finished by the `reconcile --sid <other> --orphans`
# CLI (the command the status skill offers) instead of the next session's start: its finish pass runs
# the watcher's end pass for the ended session too (lib/watchcall.pm finished, the hooks' own), so the
# held A-01s are settled and the A-01 whose copy landed is closed exactly as through the hook.
my $case = do {
    local $T::AN_FINISH = 'cli';
    my $f = __FILE__;
    $f =~ s{AT-AN-21-a01-finish-cli/case\.pl\z}{AT-AN-16-a01-session-end/case.pl} or die "AT-AN-21: path $f\n";
    do $f;
};
die "AT-AN-21: AT-AN-16 did not load: $@\n" unless ref $case eq 'HASH';
$case;

# run by AT-RN-07 only (the driver's default list reads only the folders beside _driver), from an
# inner driver started with GIT_DIR at a stand-in repo, STORE_TEST_TRACE at a stand-in file and the
# state folders at stand-ins: the driver's fresh environment keeps none of them, so this case's
# environment holds no CLAUDE*, XDG_* or GIT_* name and no STORE_* name but the driver's own
# (STORE_TEST_MODE, STORE_TEST_NOW), and its fixture git commands (git init, git commit) land in
# its own $TMP/r, never in the stand-in repo.
my @bad;
{
    steps => [ { call => 'code', code => sub {
        my $v = shift;
        push @bad, "the case's environment holds $_ (the driver starts from a fresh one)"
            for sort grep { /\A(?:CLAUDE|XDG_|GIT_)/ || (/\ASTORE_/ && !/\ASTORE_TEST_(?:MODE|NOW)\z/) } keys %ENV;
        watch::io::mkdir_p("$v->{TMP}/r");
        T::_git("$v->{TMP}/r", 'init', '-q');
        T::_git("$v->{TMP}/r", 'commit', '-q', '--allow-empty', '-m', 'fixture-commit');
        return;
    } } ],
    expect => sub {
        my ($E) = @_;
        $E->ok(-d $E->var('TMP') . '/r/.git', "the fixture repo is the case's own");
        $E->ok(0, $_) for @bad;
    },
};

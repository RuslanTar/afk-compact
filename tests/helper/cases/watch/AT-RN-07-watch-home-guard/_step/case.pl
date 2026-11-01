# run by AT-RN-07 only (the driver's default list reads only the folders beside _driver): the
# first step leaves HOME outside the temp folders, and the driver refuses the second step before
# it runs, so this case fails with `died: HOME-GUARD: step code: ...`. Neither step starts anything.
{
    steps => [ { call => 'code', code => sub { $ENV{HOME} = '/nonexistent-home-guard'; return } },
               { call => 'code', code => sub { return } } ],
};

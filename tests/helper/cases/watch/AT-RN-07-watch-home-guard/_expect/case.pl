# run by AT-RN-07 only (the driver's default list reads only the folders beside _driver): the
# last step leaves HOME outside the temp folders, and the driver refuses the expect sub before it
# runs, so this case fails with `died: HOME-GUARD: expect: ...`. The sub itself starts nothing.
{
    steps => [ { call => 'code', code => sub { $ENV{HOME} = '/nonexistent-home-guard'; return } } ],
    expect => sub { my ($E) = @_; $E->ok(1, 'the expect sub ran') },
};

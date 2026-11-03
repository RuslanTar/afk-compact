# AT-AN-15 (0.1.3 alerts, root call 3b): the first plugin hook a session runs is a Stop (the plugin
# was installed or reloaded mid-session on the classic path), so the session has no row yet when
# that Stop's rules run. That Stop's own start is where observing began: a boundary from before it
# with no hook row or dispatch of its own is history (no A-01, hookless A-15 or A-05). A boundary
# after it, read at the next Stop, raises all three.
{
    settings => { native_window_tokens => 800000 },
    transcript => [
        T::prompt(0), T::assistant_text(5),
        T::boundary(100, trigger => 'auto', preTokens => 250000), T::summary(100.1),
        T::prompt(1900), T::assistant_text(1910),
    ],
    steps => [
        { call => 'stop', at => 2000 },
        { call => 'append', rows => [ T::boundary(2100, trigger => 'auto', preTokens => 250000), T::summary(2100.1), T::prompt(2150) ] },
        { call => 'stop', at => 2200 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->boundaries ], 2, 'two boundaries recorded');
        for my $rule (qw(A-01 A-05)) {
            my @a = $E->alerts($rule);
            $E->count(\@a, 1, "$rule only for the boundary after the first Stop");
            $E->is($a[0]{key}{compaction_seq}, 2, "$rule names the later compaction") if @a;
        }
        my @h = grep { $_->{evidence}{hookless_boundary} } $E->alerts('A-15');
        $E->count(\@h, 1, 'hookless A-15 only for the later boundary');
        $E->is($h[0]{key}{compaction_seq}, 2, 'A-15 names the later compaction') if @h;
    },
};

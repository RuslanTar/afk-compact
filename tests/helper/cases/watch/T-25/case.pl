# T-25 (M-01): an auto boundary right after a prompt row vs after a
# tool_use with no Stop -> auto-turnstart vs auto-midturn.
{
    transcript => [
        T::prompt(0),
        T::boundary(1, trigger => 'auto'), T::summary(1.1),
        T::assistant_text(10),
        T::prompt(50),
        T::bash(55, 'make', id => 'toolu_1'),
        T::boundary(60, trigger => 'auto'), T::summary(60.1),
    ],
    steps => [ { call => 'stop', at => 90 } ],
    expect => sub {
        my ($E) = @_;
        my @b = $E->boundaries;
        $E->is($b[0]{trigger_detail}, 'auto-turnstart', 'after a prompt row');
        $E->is($b[1]{trigger_detail}, 'auto-midturn', 'after a tool_use with no Stop');
    },
};

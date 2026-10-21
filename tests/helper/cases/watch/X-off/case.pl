# WATCH §8.6: `watcher: off` removes every watcher code path. Plugin-core
# writes (core's) are not part of the watcher library, so nothing is written.
my $body = "# CANARY-TEXT-topic\n";
{
    settings => { watcher => 'off' },
    transcript => [ T::prompt(0), T::boundary(10, trigger => 'auto'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => undef } },
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'unshaped', normalized => $body } } },
        { call => 'hook', event => 'PermissionDenied', at => 12, payload => { tool_name => 'Bash', reason => 'x' } },
        { call => 'hook', event => 'StopFailure', at => 13, payload => { error => 'overloaded' } },
        { call => 'stop', at => 30 },
        { call => 'status', at => 31 },
    ],
    expect => sub {
        my ($E) = @_;
        my $w = $E->var('WATCH');
        my @left = -d $w ? do { opendir(my $d, $w); grep { !/\A\.\.?\z/ } readdir $d } : ();
        $E->count(\@left, 0, 'nothing written under the watch dir');
        my ($lines) = $E->outputs;
        $E->is($lines->[0], 'Watcher: off', 'status says off');
    },
};

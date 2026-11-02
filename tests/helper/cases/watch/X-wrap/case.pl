# The entry-point wrapper (lib/watch.pm; BUILD-PLAN §3.1 hook rules): an
# internal error in on_hook, on_stop or status_lines prints nothing, writes
# nothing to stderr and leaves one `watch_error {stage, error_class}` row. A
# die message that is not a plain class becomes `internal`, so its text never
# reaches a row. A Stop that failed keeps no offset: the next Stop reads the
# same bytes. Internals are swapped for dying stubs here and put back after.
my %orig;
my $swap = sub {
    my ($name, $code) = @_;
    no strict 'refs';
    no warnings 'redefine';
    $orig{$name} //= \&{$name};
    *{$name} = $code;
};
{
    # the session's first row (0.1.3: a session with only the Stop's own rows is observed from the
    # first of them, and this boundary would be history)
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('config_note', 0, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'auto', preTokens => 450000), T::summary(10.1), T::prompt(20) ],
    steps => [
        { call => 'code', code => sub {
              require watch::hooks; require watch::rules; require watch::status;
              $swap->('watch::hooks::post_compact', sub { warn "CANARY-TEXT-warn\n"; die "CANARY-TEXT-boom\n" });
              $swap->('watch::hooks::pre_compact', sub { die "disk-full\n" });
              $swap->('watch::rules::evaluate', sub { die { CANARY => 'CANARY-TEXT-ref' } });
              $swap->('watch::status::lines', sub { die "CANARY-TEXT-status\n" });
          } },
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => 'CANARY-TEXT-s' } },
        { call => 'hook', event => 'PreCompact', at => 12, payload => { trigger => 'manual' } },
        { call => 'stop', at => 30 },
        { call => 'status', at => 31 },
        { call => 'code', code => sub {
              no strict 'refs';
              no warnings 'redefine';
              *{$_} = $orig{$_} for keys %orig;
          } },
        { call => 'stop', at => 60 },
    ],
    expect => sub {
        my ($E) = @_;
        my @e = map { "$_->{stage}/$_->{error_class}" } $E->rows('classic', 'watch_error');
        $E->is(join(',', @e), 'hook-PostCompact/internal,hook-PreCompact/disk-full,rules/internal',
               'one watch_error row per failed entry, classes only');
        my ($lines) = $E->outputs;
        $E->is(ref $lines eq 'ARRAY' ? join('|', @$lines) : undef, 'Watcher: status unavailable', 'status fallback line');
        $E->count([ $E->rows('classic', 'postcompact') ], 0, 'no partial postcompact row');
        $E->count([ $E->boundaries ], 1, 'the failed Stop kept no offset; the next Stop swept the boundary');
        $E->count([ $E->alerts('A-01') ], 1, 'and evaluated it');
    },
};

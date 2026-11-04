# AT-AN-31 (0.1.4 W-2, review F-3): the plugin is installed mid-session, so its first Stop sweeps the
# whole history at once: a boundary from before the session's first plugin row and a plugin continue
# after it, in the same Stop. The continue's boundary is a history boundary: no A-27. This path reads
# what evaluate keeps of the boundary in that same Stop (session state `bmeta`, its `hist` flag), not
# the fallback by boundary time that AT-AN-19 exercises.
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 500, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), T::boundary(100, uuid => 'b-hist-same', trigger => 'auto'), T::summary(100.1),
                    T::continue_row(200), T::assistant_text(201) ],
    steps => [ { call => 'stop', at => 550 } ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->alerts('A-27') ], 0, 'no A-27 for a continue after a history boundary swept in the same Stop');
    },
};

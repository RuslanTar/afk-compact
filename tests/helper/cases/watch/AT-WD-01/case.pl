# AT-WD-01 (small-rulings §4.1 item 1; REVIEW B-22): `watcher` is trimmed and case-folded
# first. `off`/`OFF`/`OFF ` turn the watcher off; `shadow`/`SHADOW ` keep it on with no
# note; anything else (`Shadow2`, `of`, empty) keeps it on and writes ONE `config_note`
# row (`watcher_value_unknown`, no value in it) per session, and `status` says so.
my @cases = (
    # [sid8, value, on, note]
    ['aaaa0001', 'Shadow2', 1, 1],
    ['aaaa0002', 'of',      1, 1],
    ['aaaa0003', '',        1, 1],
    ['aaaa0004', 'off',     0, 0],
    ['aaaa0005', 'OFF',     0, 0],
    ['aaaa0006', 'OFF ',    0, 0],
    ['aaaa0007', ' Off',    0, 0],
    ['aaaa0008', 'SHADOW ', 1, 0],
    ['aaaa0009', 'shadow',  1, 0],
);
my @steps;
for my $c (@cases) {
    my ($sid, $val) = @$c;
    my %ctx = (sid => $sid, settings => { watcher => $val });
    push @steps, { call => 'hook', event => 'PreCompact', at => 9, payload => { session_id => $sid, trigger => 'auto', custom_instructions => undef }, ctx => \%ctx };
}
# the same session again: still one note row
push @steps, { call => 'hook', event => 'PreCompact', at => 10,
               payload => { session_id => 'aaaa0002', trigger => 'auto', custom_instructions => undef },
               ctx => { sid => 'aaaa0002', settings => { watcher => 'of' } } };
push @steps, { call => 'status', at => 11, ctx => { sid => 'aaaa0002', settings => { watcher => 'of' } } };
push @steps, { call => 'status', at => 12, ctx => { sid => 'aaaa0009', settings => { watcher => 'shadow' } } };
{
    steps => \@steps,
    expect => sub {
        my ($E) = @_;
        my $w = $E->var('WATCH');
        for my $c (@cases) {
            my ($sid, $val, $on, $note) = @$c;
            my $f = "$w/$sid.classic.jsonl";
            my @pre = $E->rows($f, 'precompact');
            my @cn = $E->rows($f, 'config_note');
            $E->count(\@pre, $on ? ($sid eq 'aaaa0002' ? 2 : 1) : 0, "'$val': watcher " . ($on ? 'on' : 'off'));
            $E->count(\@cn, $note, "'$val': config_note rows");
            if ($note) {
                $E->is($cn[0]{key}, 'watcher', "'$val': note key");
                $E->is($cn[0]{note}, 'watcher_value_unknown', "'$val': note text");
            }
        }
        my ($of_lines, $ok_lines) = $E->outputs;
        $E->ok((grep { /watcher setting is not true or false; it counts as true/ } @$of_lines) == 1, 'status notes the unknown value');
        $E->ok(!(grep { /watcher setting is not/ } @$ok_lines), 'no note for shadow');
    },
};

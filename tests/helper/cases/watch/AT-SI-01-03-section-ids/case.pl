# AT-SI-01…03 (stable section ids): a beta report names each handoff section by a fixed id
# (`main:next-steps`), never by
# its position, and says spec_version 2 once.
# - SI-01: the shipped spec (plugin/assets/handoff-spec.json) is spec_version 2 and gives every
#   heading of sections_main a `main:<role>` id and every heading of sections_subagent a
#   `sub:<role>` id in `section_ids`: one each, unique, no stale entry, distinct slugs; the ids
#   pinned below never change (a renamed heading keeps its id, a new heading gets a new one).
# - SI-02: the export transform maps a heading literal, the slug a section_chars row holds and
#   the id itself to that id; a position id, an unknown heading or slug becomes `other`;
#   `preamble` stays. A spec_version 1 spec, or an id of the wrong form, maps nothing.
# - SI-03: `report verify` follows the manifest's spec_version: none or 1 takes position ids and
#   slugs and refuses a fixed id; 2 takes fixed ids (and `preamble`/`other`) only and refuses a
#   position id or a slug; a bundle that mixes the two fails; a bad spec_version fails.
use Cwd ();
use File::Basename ();
# sha256 through core's sha::hex256 (Digest::SHA when it loads, else the embedded one; the driver loads it)
my $plugin = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin');
# The ids as first shipped (spec_version 2). Never change one; add a new heading's id here.
my %PIN = (
    '## Resume here' => 'main:resume-here', '## User constraints' => 'main:user-constraints',
    '## Approvals' => 'main:approvals', '## Decisions and do-not-re-raise' => 'main:decisions',
    '## In flight' => 'main:in-flight', '## Live state' => 'main:live-state', '## Open questions' => 'main:open-questions',
    '## Location' => 'main:location', '## Work done and findings' => 'main:work-done', '## Evidence' => 'main:evidence',
    '## Next steps' => 'main:next-steps', '## Task as assigned' => 'sub:task',
    '## Constraints from the parent' => 'sub:parent-constraints', '## Report' => 'sub:report', '## Done' => 'sub:done',
    '## Findings' => 'sub:findings', '## Produced but not yet delivered' => 'sub:undelivered',
    '## Own background tasks' => 'sub:background-tasks', '## Next action' => 'sub:next-action',
);
my $RN = 'rows/0123456789ab.jsonl';
# A minimal bundle: the manifest (with spec_version when given) and one rows file of postcompact
# rows, one per section_chars object.
my $mk = sub {
    my ($path, $sv, @sc) = @_;
    my $rows = join('', map { watch::json::encode({ v => 1, ev => 'postcompact', ts => '2026-10-21T14:00:00.000+03:00',
                                                    sid => 'abcdef012345', section_chars => $_ }) . "\n" } @sc);
    my $m = { schema => "$T::BRAND-report/1", plugin => $T::BRAND, install_id => '0123456789abcdef',
              files => [ { name => $RN, bytes => length $rows, sha256 => sha::hex256($rows) } ],
              withheld => [], dropped => {}, (defined $sv ? (spec_version => $sv) : ()) };
    require watch::bundle;
    main::write_file($path, watch::bundle::zip([ [ 'README.txt', "report\n" ], [ 'manifest.json', watch::json::encode($m) . "\n" ],
                                                 [ $RN, $rows ] ], $T::BASE), 0600);
};
my $fixed_fail = qr/^VERIFY FAIL section ids: rows\/0123456789ab\.jsonl holds an id that is not a fixed section id \(manifest spec_version 2\)$/m;
my $pos_fail = qr/^VERIFY FAIL section ids: rows\/0123456789ab\.jsonl holds a fixed section id \(manifest spec_version (?:none|1)\)$/m;
{
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $t = $v->{TMP};
              $mk->("$t/v1.zip", undef, { 'main:3' => 100, resume_here => 5, other => 1, preamble => 2 });
              $mk->("$t/v1-explicit.zip", 1, { 'main:3' => 100, 'sub:2' => 4 });
              $mk->("$t/v2.zip", 2, { 'main:next-steps' => 100, 'sub:done' => 4, preamble => 3, other => 1 });
              $mk->("$t/v2-position.zip", 2, { 'main:next-steps' => 100, 'main:3' => 4 });
              $mk->("$t/v2-slug.zip", 2, { resume_here => 5 });
              $mk->("$t/v1-fixed.zip", undef, { 'main:next-steps' => 100 });
              $mk->("$t/v1-explicit-fixed.zip", 1, { 'main:3' => 1 }, { 'sub:done' => 2 });
              $mk->("$t/v1-mixed.zip", undef, { 'main:3' => 1 }, { 'main:next-steps' => 2 });
              $mk->("$t/bad-version.zip", '2x', { 'main:next-steps' => 1 });
              $mk->("$t/zero-version.zip", 0, { 'main:3' => 1 });
          } },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v1.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v1-explicit.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v2.zip' ], stdout_re => qr/\AVERIFY OK\n\z/ },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v2-position.zip' ], exit => 1, stdout_re => $fixed_fail },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v2-slug.zip' ], exit => 1, stdout_re => $fixed_fail },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v1-fixed.zip' ], exit => 1, stdout_re => $pos_fail },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v1-explicit-fixed.zip' ], exit => 1, stdout_re => $pos_fail },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/v1-mixed.zip' ], exit => 1, stdout_re => $pos_fail },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/bad-version.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL manifest: spec_version$/m },
        { call => 'cli', argv => [ 'report', 'verify', '--zip', '$TMP/zero-version.zip' ], exit => 1,
          stdout_re => qr/^VERIFY FAIL manifest: spec_version$/m },
    ],
    expect => sub {
        my ($E) = @_;
        require watch::export;
        require watch::shape;
        # SI-01: the shipped spec
        my $spec = watch::io::read_json_file("$plugin/assets/handoff-spec.json") || {};
        $E->is($spec->{spec_version}, 2, 'SI-01: the shipped spec is spec_version 2');
        my $ids = ref $spec->{section_ids} eq 'HASH' ? $spec->{section_ids} : {};
        my (%seen, %slug, @all);
        for my $k ([ 'sections_main', 'main' ], [ 'sections_subagent', 'sub' ]) {
            for my $h (@{ $spec->{ $k->[0] } || [] }) {
                push @all, $h;
                my $id = $ids->{$h} // '';
                $E->ok(($id =~ /\A\Q$k->[1]\E:[a-z][a-z-]{0,31}\z/ ? 1 : 0), "SI-01: '$h' has a $k->[1]: id ($id)");
                $E->ok((!$seen{$id}++ ? 1 : 0), "SI-01: id $id is used once");
                $E->ok((!$slug{ watch::shape::_slug($h) }++ ? 1 : 0), "SI-01: the slug of '$h' is its own");
            }
        }
        my %listed = map { $_ => 1 } @all;
        $E->ok(0, "SI-01: section_ids has '$_', which is no heading") for grep { !$listed{$_} } sort keys %$ids;
        my %shipped = map { $_ => 1 } values %$ids;
        for my $h (sort keys %PIN) {
            $E->ok(($shipped{ $PIN{$h} } ? 1 : 0), "SI-01: pinned id $PIN{$h} still ships");
            $E->is($ids->{$h}, $PIN{$h}, "SI-01: '$h' keeps its id") if exists $ids->{$h};
        }
        # SI-02: the transform over the shipped spec
        my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => watch::export::heading_ids($spec) };
        my $row = sub {
            my ($sc) = @_;
            my $r = watch::export::transform_row({ ev => 'postcompact', ts => '2026-10-21T14:00:00.000+03:00', section_chars => $sc }, $X);
            my $o = ref $r eq 'HASH' ? $r->{section_chars} || {} : {};
            return join(',', map { "$_=$o->{$_}" } sort keys %$o);
        };
        $E->is($row->({ '## Next steps' => 10, next_steps => 5, 'main:next-steps' => 7, resume_here => 3, decisions_and_do => 8,
                        '## Done' => 2, 'main:3' => 2, 'sub:2' => 1, 'Next steps' => 6, preamble => 4, other => 1, 'main:bogus' => 1 }),
               'main:decisions=8,main:next-steps=22,main:resume-here=3,other=11,preamble=4,sub:done=2',
               'SI-02: literal, slug and id map to the fixed id; positions and unknowns become other');
        my %v1 = (%$spec, spec_version => 1);
        $X->{headings} = watch::export::heading_ids(\%v1);
        $E->is($row->({ '## Next steps' => 10, next_steps => 5, preamble => 1 }), 'other=15,preamble=1',
               'SI-02: a spec_version 1 spec maps no heading (no fixed id under spec_version 1)');
        my %wrong = (%$spec, section_ids => { %$ids, '## Done' => 'main:done', '## Next steps' => 'main:Next' });
        $X->{headings} = watch::export::heading_ids(\%wrong);
        $E->is($row->({ '## Done' => 2, done => 1, '## Next steps' => 3, '## Report' => 4 }), 'other=6,sub:report=4',
               'SI-02: an id of the wrong form or the other form maps nothing');
        $E->is(watch::export::vocabulary('brandx', $spec)->{'next-steps'}, 1, 'SI-02: a section role is a bundle word (no identity hit)');
    },
};

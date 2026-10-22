# AT-WB-01 / AT-WB-02, the round-9 fields (W-BETA B.2; BUILD-ROUND-9 WCH-09, CROSS-REVIEW §4
# item 3): every content-free field the other work packages added this round has an export
# class, so it is exported as its class and never dropped as unknown:
#   core (needs/core-to-watch.md §3, §5, §6, §7): session scratchpad / under_temp_root, rollup
#     proof / proof_lag_ms / settle_waited_ms / sentinel_place / resume values, idle as a JSON
#     bool or `unknown` (rollup and compaction_boundary, which also carries idle_source and
#     idle_gap_s), copy_attributed proof `slot`, queue_contract why values, finished_by;
#   skills (needs/skills-to-watch.md): heal prod_class and effects prod-read/prod-write,
#     handoff_publish attempt / template_rev / acuity / acuity_floor, resume_receipt cmds_asked;
#   mod (needs/mod-to-watch.md): handoff_skipped reason precompact, handoff_turn_end compaction
#     (bool), submit_dropped site, config_effective null thresholds, the _raw values,
#     small_window and min_window (a number or `never`), dispatch idle_gap_s.
# Rows are given as the watcher reads them (watch::json decodes booleans to 1 and 0).
my %got;
my @rows = (
    { ev => 'session', phase => 'start', source => 'startup', scratchpad => 'present', under_temp_root => 1 },
    { ev => 'session', phase => 'start', source => 'clear', scratchpad => 'absent', under_temp_root => undef },
    { ev => 'compaction', nonce => 'ab0c0001', idle => 'unknown', idle_source => undef, proof => 'none', proof_lag_ms => undef,
      settle_waited_ms => 1200, sentinel_place => 'after-close', resume => 'dropped:session-end', acuity => 'watch',
      acuity_floor => '-' },
    { ev => 'compaction', nonce => 'ab0c0002', idle => 1, idle_source => 'both', idle_gap_s => 3235, proof => 'P3',
      proof_lag_ms => -42, resume => 'undelivered' },
    { ev => 'compaction', nonce => 'ab0c0003', idle => 0, idle_source => 'none', proof => 'P1', resume => 'pending' },
    { ev => 'compaction_boundary', nonce => 'ab0c0002', id6 => 'ab0c00', boundary_uuid => 'u-1', pre_tokens => 223438,
      post_tokens => 14943, duration_ms => 55960, precomputed => 0, idle => 1, idle_source => 'notice', idle_gap_s => 3235,
      cc_version => '2.1.306', cc_version_src => 'transcript' },
    { ev => 'copy_attributed', id6 => 'ab0c00', nonce => 'ab0c0002', from_rel => undef,
      rel_path => 'repo/b/compact/subagents/x-a1b2c3d4.md', actor => 'a5c0ffee0a1b2c3d4', proof => 'slot', seq => 2,
      pre_tokens => 1, post_tokens => 2, finished_by => 'abcdef12' },
    (map { { ev => 'queue_contract', why => $_ } } qw(untagged schema not-json exit timeout)),
    { ev => 'heal', result => 'REFUSED:effects-prod-read', effects => 'prod-read', prod_class => 'prod-token' },
    { ev => 'heal', result => 'ok', effects => 'prod-write', prod_class => 'user-prod-3' },
    { ev => 'handoff_publish', result => 'wrote', bytes => 4000, attempt => 2, template_rev => '0a1b2c3d', acuity => 'unstable',
      acuity_floor => 'watch', lint_rules => [ 'acuity', 'store-path' ] },
    { ev => 'resume_receipt', relation => 'own', calls => 2, cmds_asked => 1 },
    { ev => 'resume_receipt', relation => 'own', calls => 2, cmds_asked => undef },
    { ev => 'handoff_skipped', why => 'asks-user', reason => 'precompact', ht => undef },
    { ev => 'handoff_skipped', why => 'ttl-5m', reason => 'idle', ht => undef },
    { ev => 'handoff_turn_start', ht => 'abcd0001', reason => 'precompact', turn_id => 'p-1', t0 => 1, max_calls => 34 },
    { ev => 'handoff_turn_end', handoff_turn => 'published', reason => 'precompact', compaction => 1, interjected => 0 },
    { ev => 'handoff_turn_end', handoff_turn => 'published', reason => 'idle', compaction => 0, cache_read_share => undef },
    { ev => 'submit_dropped', why => 'session-changed', site => 'continue' },
    { ev => 'submit_dropped', why => 'session-changed', site => 'handoff-turn' },
    { ev => 'config_effective', window => 150000, native_offset => 33000, native_trigger => 117000, reserve => 100000,
      soft_max => undef, target => undef, soft_max_raw => -7000, target_raw => -4667, disabled => 'trigger-disabled-small-window',
      small_window => 1, min_window => 'never', clamped => [] },
    { ev => 'config_effective', window => 1000000, native_offset => 33000, native_trigger => 967000, reserve => 100000,
      soft_max => 800000, target => 533333, soft_max_raw => 800000, target_raw => 533333, disabled => undef,
      small_window => 0, min_window => 253000, clamped => [ 'soft_max' ] },
    { ev => 'dispatch', nonce => 'ab0c0004', trigger => 'auto', channel => 'mod-hook', idle => 1, idle_gap_s => 1800 },
    { ev => 'compacted', nonce => 'ab0c0004', skip => 'native-ran', ms => undef, handoff_ht => 'abcd0001' },
    { ev => 'orphan_finished', sid => '5e55a001-0c0f-4f1e-9a00-00000000a001', saved => 1, kept => 0, left => 2 },
    { ev => 'stash_kept', id6 => 'ab0c00', nonce => 'ab0c0002', why => 'mismatch', redacted_n => 3 },
    { ev => 'idle_mismatch', nonce => 'ab0c0002' },
    { ev => 'resume_remeasured', nonce => 'ab0c0002', age_s => 700, ms => 120 },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-21T14:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'helper', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        my $b = sub { my $v = shift; return ref $v eq 'SCALAR' ? ($$v ? 'true' : 'false') : defined $v ? "<$v>" : 'null' };
        my $i = 0;
        my %r = map { $i++ => $_ } @o;
        $E->is($r{0}{scratchpad}, 'present', 'session scratchpad');
        $E->is($b->($r{0}{under_temp_root}), 'true', 'session under_temp_root bool');
        $E->is($r{1}{scratchpad}, 'absent', 'scratchpad absent');
        $E->is($b->($r{1}{under_temp_root}), 'null', 'under_temp_root null');
        $E->is($r{2}{idle}, 'unknown', 'rollup idle unknown kept as the word');
        $E->is($r{2}{proof}, 'none', 'rollup proof');
        $E->is($r{2}{settle_waited_ms}, 1200, 'settle_waited_ms');
        $E->is($r{2}{sentinel_place}, 'after-close', 'sentinel_place');
        $E->is($r{2}{resume}, 'dropped:session-end', 'resume dropped:session-end');
        $E->is($r{2}{acuity}, 'watch', 'rollup acuity');
        $E->is($r{2}{acuity_floor}, '-', 'rollup acuity_floor -');
        $E->is($b->($r{3}{idle}), 'true', 'rollup idle as a bool');
        $E->is($r{3}{idle_source}, 'both', 'idle_source');
        $E->is($r{3}{idle_gap_s}, 3235, 'idle_gap_s');
        $E->is($r{3}{proof}, 'P3', 'proof P3');
        $E->is($r{3}{proof_lag_ms}, -42, 'proof_lag_ms');
        $E->is($r{3}{resume}, 'undelivered', 'resume undelivered');
        $E->is($b->($r{4}{idle}), 'false', 'rollup idle false');
        $E->is($r{4}{resume}, 'pending', 'resume pending');
        $E->is($b->($r{5}{idle}), 'true', 'boundary idle');
        $E->is($r{5}{idle_source}, 'notice', 'boundary idle_source');
        $E->is($r{5}{idle_gap_s}, 3235, 'boundary idle_gap_s');
        $E->is($r{5}{cc_version_src}, 'transcript', 'cc_version_src');
        $E->is($r{5}{boundary_uuid}, 'h' x 12, 'boundary uuid hashed');
        $E->is($r{6}{proof}, 'slot', 'copy_attributed proof slot');
        $E->is($r{6}{rel_path}, 'subagents', 'copy_attributed rel_path as its slot');
        $E->is($r{6}{actor}, 'h' x 12, 'agent id hashed');
        $E->is($r{6}{finished_by}, 'h' x 12, 'finished_by hashed');
        $E->is(join(',', map { $r{$_}{why} } 7 .. 11), 'untagged,schema,not-json,exit,timeout', 'queue_contract why values');
        $E->is($r{12}{effects}, 'prod-read', 'heal effects prod-read');
        $E->is($r{12}{prod_class}, 'prod-token', 'heal prod_class');
        $E->is($r{12}{result}, 'REFUSED:effects-prod-read', 'heal REFUSED class kept');
        $E->is($r{13}{prod_class}, 'user-prod-3', 'user prod class id');
        $E->is($r{14}{attempt}, 2, 'handoff_publish attempt');
        $E->is($r{14}{template_rev}, '0a1b2c3d', 'template_rev');
        $E->is($r{14}{acuity}, 'unstable', 'publish acuity');
        $E->is($r{14}{acuity_floor}, 'watch', 'publish acuity_floor');
        $E->is(join(',', @{ $r{14}{lint_rules} || [] }), 'acuity,store-path', 'lint rule ids');
        $E->is($r{15}{cmds_asked}, 1, 'resume_receipt cmds_asked');
        $E->ok((exists $r{16}{cmds_asked} && !defined $r{16}{cmds_asked} ? 1 : 0), 'cmds_asked null kept as null');
        $E->is($r{17}{reason}, 'precompact', 'handoff_skipped reason precompact');
        $E->is($r{17}{why}, 'asks-user', 'precompact why');
        $E->is($r{18}{reason}, 'idle', 'handoff_skipped reason idle');
        $E->is($r{19}{reason}, 'precompact', 'handoff_turn_start reason precompact');
        $E->is($b->($r{20}{compaction}), 'true', 'handoff_turn_end compaction bool');
        $E->is($b->($r{21}{compaction}), 'false', 'idle end compaction false');
        $E->is($r{22}{site}, 'continue', 'submit_dropped site');
        $E->is($r{23}{site}, 'handoff-turn', 'submit_dropped site handoff-turn');
        $E->is($b->($r{24}{soft_max}), 'null', 'disabled soft_max null');
        $E->is($r{24}{soft_max_raw}, -7000, 'soft_max_raw negative kept');
        $E->is($r{24}{min_window}, 'never', 'min_window never');
        $E->is($r{24}{disabled}, 'trigger-disabled-small-window', 'disabled word');
        $E->is($b->($r{24}{small_window}), 'true', 'small_window');
        $E->is($r{25}{min_window}, 253000, 'min_window number');
        $E->is($r{26}{idle_gap_s}, 1800, 'dispatch idle_gap_s');
        $E->is($r{27}{skip}, 'native-ran', 'compacted skip native-ran');
        $E->is($r{28}{left}, 2, 'orphan_finished counts');
        $E->is($r{28}{sid}, 'h' x 12, 'orphan_finished sid hashed');
        $E->is($r{29}{redacted_n}, 3, 'stash_kept');
        $E->is($r{31}{age_s}, 700, 'resume_remeasured');
    },
};

package watch::export_schema;
# lib/watch/export_schema.pm: the allowlist export schema of `report` and `watch report
# --export` (WATCHER-SPEC §8.1, W-BETA B.2). Owner: WP-watch.
#
# One class per field, per `ev`. Anything not listed is dropped and counted: a field missing
# here is dropped (manifest `dropped{"ev.field"}`), and an `ev` missing here drops the whole
# row (`dropped{"ev"}`). No value passes as free text. Classes:
#   num, int, bool      numbers and booleans as they are (anything else: dropped)
#   nonce, id6, hex8, hex12, stamp, ts, version   checked against their pattern (else dropped)
#   model               a model id as Claude Code names it (MG-4; a public product id), else dropped
#   hash                HMAC-SHA256 under the local salt, first 12 hex (sid, agent, task, ht, ...)
#   actor               main/unknown/sub/sub-unknown/unattributed kept, any other value hashed
#   slot                a path becomes main, subagents or unattributed (else other)
#   [enum => @values]   the value if listed, else `other`
#   [pre => [@values], [@prefixes]]   a listed value, or `<prefix>:<class word>` (word kept when
#                       it is a short lowercase class word, else `<prefix>:other`), else `other`
#   word                a short lowercase class word made by code ([a-z][a-z0-9_-]{0,31}), else other
#   tool                a tool name: a Claude Code built-in name (@BUILTIN_TOOLS) as it is, any
#                       `mcp__<server>__<tool>` name (and the sweep's own `mcp`) as `mcp`, else
#                       `other`; an MCP server name is the user's own word and never exported
#   rule                an alert rule id (A-NN), else dropped
#   [list => CLASS]     an array; each item through CLASS (items that fail are dropped)
#   [counts => CLASS]   an object {key: number}; keys through CLASS (word by default), values num
#   [obj => {...}]      a nested object with its own field classes
#   heading             a spec section heading (its literal, or the slug a section_chars row
#                       holds) becomes its fixed section id from the spec's `section_ids`
#                       (`main:<role>`/`sub:<role>`, spec_version 2; owner xxxxxxxx-34), else
#                       `other`; `preamble` and `other` stay as they are
#   [or => CLASS, @words]  one of the listed words as it is, else the value through CLASS
#                       (idle: a bool or `unknown`; min_window: a number or `never`)
#   drop                never exported (listed so the gate knows it was looked at)
use strict;
use warnings;
use utf8;

our $VERSION = 1;

my @VERDICT = qw(ok ok-trailer unshaped truncated stale scope-leak none);
my @TRIGGER = qw(auto manual plugin precompute unknown);
my @CHANNEL = qw(mod-hook mod-self classic none sessionstart prompt.context prompt.submit);
my @SEAT = qw(mod-hook mod-self classic-only none);
my @WRITER = qw(mod classic helper watch);
my @BAND = qw(near spent imminent);
my @HT_REASON = qw(halt cap precompact idle last-cycle nonok thrash manual);
my @HT_END = qw(published none race aborted);
my @SKIP_WHY = qw(user-turn headroom compacted asks-user cap no-asset open-failed submit-failed again
                  triggers-off small-window session-changed busy aborted small ttl-5m near-limit episode published
                  cooldown disabled halted precompute in-flight native-on native-unknown
                  native-fired agents-running);
my @IDLE_SRC = qw(mod notice return both none);
# core writes idle as a JSON bool once reconcile settled it (compaction_boundary, rollup), and
# `unknown` before (needs/core-to-watch.md §6)
my $IDLE = [or => 'bool', 'unknown'];
my @ACUITY = qw(stable watch unstable -);
# Claude Code's own tool names (fixed by Claude Code, the same for every install): the only tool
# names the `tool` class keeps. A name not listed here becomes `other`.
our @BUILTIN_TOOLS = qw(Agent AskUserQuestion Bash BashOutput CronCreate CronDelete CronList Edit EnterPlanMode
                        ExitPlanMode Glob Grep KillBash KillShell LS ListMcpResourcesTool LSP Monitor MultiEdit
                        NotebookEdit NotebookRead Read ReadMcpResourceTool SendMessage Skill SlashCommand Task
                        TaskCreate TaskGet TaskList TaskOutput TaskStop TaskUpdate TodoRead TodoWrite ToolSearch
                        WebFetch WebSearch Workflow Write);
my %BUILTIN_TOOL = map { $_ => 1 } @BUILTIN_TOOLS;
sub builtin_tool { my ($v) = @_; return defined $v && !ref $v && $BUILTIN_TOOL{$v} ? 1 : 0 }
my @SEVERITY = qw(critical warn info);

my %ENVELOPE = (
    v => 'int', ts => 'ts', ev => 'word', sid => 'hash', actor => 'actor', writer => [enum => @WRITER],
    pid => 'drop', plugin_version => 'version', cc_version => 'version', turn_seq => 'int',
    finished_by => 'hash', cc_version_src => [enum => qw(mod exec transcript mirror)],
);
sub envelope { return \%ENVELOPE }

our %SCHEMA = (
    # --- the rollup row (MOD-SPEC §2.5) and its boundary join (PKG-RUNTIME E.2) ---
    compaction => {
        session_id => 'hash', compaction_seq => 'int', nonce => 'nonce', id6 => 'id6', join => 'word',
        trigger => [enum => @TRIGGER], midturn => 'bool', idle => $IDLE,
        idle_source => [enum => @IDLE_SRC], idle_gap_s => 'num', channel => [enum => @CHANNEL],
        seat_state => [enum => @SEAT], verdict => [enum => @VERDICT], verdict_source => [enum => qw(postcompact after-step)],
        marker_line => 'int', sentinel_from_end => 'int', sentinel_place => [enum => qw(inside after-close)],
        fabricated_check_tokens => 'int', instructions_bytes => 'int', summary_chars => 'int', shape_class => 'word',
        pre_tokens => 'num', post_tokens => 'num', duration_ms => 'num', precomputed => 'bool',
        copy => [pre => [qw(saved exists late unattributed)], [qw(failed)]], copy_path => 'slot',
        resume => [pre => [qw(undelivered none-subagent pending)], [qw(delivered dropped)]],
        checkpoint_ms => [counts => 'word'], evidence => [counts => 'word'], nudged => 'bool', continued => 'bool',
        halt => 'word', handoff_turn => [pre => [qw(none published race aborted)], [qw(failed skipped)]],
        handoff_ht => 'hash', handoff_tokens => 'num', handoff_calls => 'int', handoff_result_chars => 'int',
        handoff_ms => 'num', handoff_headroom => 'num', acuity => [enum => @ACUITY], acuity_floor => [enum => @ACUITY],
        proof => [enum => qw(P1 P3 none)], proof_lag_ms => 'num', settle_waited_ms => 'num',
    },
    compaction_boundary => {
        nonce => 'nonce', id6 => 'id6', boundary_uuid => 'hash', pre_tokens => 'num', post_tokens => 'num',
        duration_ms => 'num', precomputed => 'bool', idle => $IDLE, idle_source => [enum => @IDLE_SRC], idle_gap_s => 'num',
    },
    # --- WATCHER-SPEC §6.3 ---
    dispatch => {
        nonce => 'nonce', trigger => [enum => @TRIGGER], agent_id => 'hash', compaction_seq => 'int',
        channel => [enum => @CHANNEL], instructions_bytes => 'int', block_bytes => 'int', measured => 'bool',
        instr_version => 'word', tokens_before => 'num', checkpoint_ms => [counts => 'word'], full_checkpoint => 'bool',
        timeouts => [list => 'word'], evidence => [counts => 'word'], approvals_checked => [list => 'word'],
        fallback => 'bool', error_class => 'word', idle => 'bool', idle_gap_s => 'num', midturn => 'bool',
        model => 'model',
    },
    precompact => {
        trigger => [enum => qw(auto manual)], ci_bytes => 'int', ci_has_nonce => 'bool', ci_nonce => 'nonce',
        ci_foreign_header => 'bool', keyset_hash => 'hex8',
    },
    compacted => {
        nonce => 'nonce', skip => 'word', tokens_before => 'num', tokens_after => 'num', usage_present => 'bool',
        ms => 'num', t0 => 'num', ht => 'hash', handoff_ht => 'hash',
    },
    postcompact => {
        trigger => [enum => qw(auto manual)], nonce_found => 'nonce', scope_found => [enum => qw(main sub manual)],
        verdict => [enum => @VERDICT], marker_line => 'int', sentinel_from_end => 'int', summary_chars => 'int',
        size_band => 'word', form => [enum => qw(main sub)], main_headings => 'int',
        section_chars => [counts => 'heading'], elements => [counts => 'word'], fabricated_check_tokens => 'int',
        measured => 'bool', measured_stamp => 'stamp',
        ledger => [obj => { lost_U => 'int', lost_D => 'int', lost_X => 'int', folded => 'int', ledger_chars => 'int',
                            overlap_pct => 'num', ledger_src => [enum => qw(copy transcript none)] }],
        clutter => [counts => 'word'], tmp_paths => 'int', arm_fp => 'hash', arm_new => 'bool',
        secret_hits => [list => 'word'], keyset_hash => 'hex8', mod_alive_this_turn => 'bool',
    },
    copy => { nonce => 'nonce', id6 => 'id6', result => [pre => [qw(saved exists late unattributed mismatch)], [qw(failed)]],
              slot => [enum => qw(main subagents unattributed)], rel_path => 'slot' },
    copy_attributed => { id6 => 'id6', nonce => 'nonce', from_rel => 'slot', rel_path => 'slot', actor => 'actor',
                         proof => [enum => qw(a b c slot)], seq => 'int', pre_tokens => 'num', post_tokens => 'num' },
    copy_attribution_ambiguous => { id6 => 'id6', candidates => 'int' },
    copy_attribution_failed => { id6 => 'id6', why => 'word' },
    stash_dropped => { id6 => 'id6', nonce => 'nonce', why => [enum => qw(redundant)], copy_rel => 'slot' },
    stash_kept => { id6 => 'id6', nonce => 'nonce', why => [enum => qw(mismatch)], redacted_n => 'int' },
    orphan_finished => { saved => 'int', kept => 'int', left => 'int' },
    resume_inject => { nonce => 'nonce', channel => [enum => @CHANNEL], bytes => 'int', nonok_note => 'bool' },
    nudge => { tokens => 'num', turn_seq => 'int', askq_open => 'bool', halt => 'bool', active => 'bool', last_cycle => 'bool' },
    continue => { result => [pre => [qw(submitted)], [qw(skipped halt)]], continues_last_hour => 'int', halt => 'word',
                  skipped => 'word' },
    # 2026-10-27 (headless probe): the rejection's class; Claude Code's own error text stays local
    compact_rejected => { nonce => 'nonce', attempt => 'int', error_class => [enum => qw(headless turn-running other)], error => 'drop' },
    # a headless load (`claude -p`, the Agent SDK, an app or editor built on it): no nudge or plugin
    # compaction in it; one row per session id (`same-load`: a new id in it, as after a /clear)
    headless => { via => [enum => qw(session-start compact-rejected same-load)] },
    session => { phase => [enum => qw(start end)], source => [enum => qw(startup resume clear compact)], reason => 'word',
                 mod_loaded => 'bool', previous_session_id => 'hash', lineage_reason => 'word', pid_lstart => 'drop',
                 scratchpad => [enum => qw(present absent)], under_temp_root => 'bool' },
    sweep => {
        file => 'hash', from_off => 'int', to_off => 'int', partial => 'bool', bad_lines => 'int', oversize_lines => 'int',
        restarted => 'bool',
        boundaries => [list => [obj => { line => 'int', uuid => 'hash', ts => 'ts', trigger => [enum => @TRIGGER],
            pre => 'num', post => 'num', duration_ms => 'num', precomputed => 'bool', dropped => 'num',
            preserved_segment => 'bool', summary_line => 'int', summary_flags => [counts => 'word'], version => 'version',
            sid_canary => 'bool', attributed => 'actor', band_position => 'word', bypass_suspected => 'bool',
            mod_off => 'bool', nonce => 'nonce', join => 'word', verdict => [enum => @VERDICT], seq => 'int',
            boundary_trigger => [enum => @TRIGGER], trigger_src => [enum => qw(dispatch boundary postcompact)],
            trigger_detail => 'word', nonce_match => 'bool', channel => [enum => @CHANNEL], copy => 'word',
            postcompact => 'bool', warm_gap_s => 'num', turns_since_prev => 'int', refill_per_turn => 'num',
            rapid_refill_run => 'int', nudge_driven => 'bool', idle => $IDLE,
            idle_source => [enum => @IDLE_SRC] }]],
        part => 'int',
        turns =>[obj => { tool_batches => 'int', tool_calls => 'int', classes => [counts => 'tool'],
            errors => [counts => 'word'], askq => [counts => 'word'], prompts => 'int', continues => 'int',
            plugin_origin_rows => 'int', handoff_turns => 'int' }],
        handoff_turn => [list => [obj => { ht => 'hash', line => 'int' }]],
    },
    stop_failure => { error_class => 'word' },
    permission_denied => { tool_name => 'tool', reason_class => 'word', guard_class => 'word',
                           turn_kind => [enum => qw(post-compaction resume nudge other)], caused_by => [enum => qw(plugin session)] },
    handoff_publish => { result => [pre => [qw(wrote)], [qw(REFUSED)]], bytes => 'int', lint_rules => [list => 'word'], size_band => 'word',
                         kind => 'word', writer => 'word', ht => 'hash',
                         attempt => 'int', template_rev => 'hex8', acuity => [enum => @ACUITY], acuity_floor => [enum => @ACUITY],
                         # AP-4 (2026-10-23): counts and outward class ids of the checked approvals, never a quote
                         approvals => [obj => { lines => 'int', checked => 'int', unchecked => 'int', hashed => 'int' }], approval_classes => [list => 'word'] },
    config_note => { key => 'word', note => 'word' },
    handoff_turn_open => { ht => 'hash', reason => [enum => @HT_REASON], max_calls => 'int', max_tokens => 'num' },
    handoff_skipped => { why => [enum => @SKIP_WHY], reason => [enum => qw(idle precompact)], ht => 'hash' },
    # IA-3 / IA-6 (idle D3, 2026-10-23): the pair at each change in a load; owner xxxxxxxx-17:
    # `check` (native on or unreadable: the 55.5-min outcome check) and the served mode Claude Code
    # cached (2b, a hint only, never used to decide)
    idle_mode => { native => [enum => qw(on off unknown)], plugin_turn => [enum => qw(on check off)], served_hint => 'word' },
    # owner xxxxxxxx-17: a break of 55.5 min or more at 200K and more with no compaction since the
    # turn end, while the setting allowed native idle compaction (native stayed silent)
    idle_silent => { gap_s => 'num', tokens => 'num', agents => 'int', served_hint => 'word' },
    handoff_turn_start => { ht => 'hash', reason => [enum => @HT_REASON], turn_id => 'hash', t0 => 'num', gap_s => 'num',
                            max_calls => 'int', max_tokens => 'num', model => 'model' },
    handoff_turn_end => {
        handoff_turn => [pre => [@HT_END], [qw(failed)]], handoff_ht => 'hash', handoff_tokens => 'num',
        handoff_calls => 'int', handoff_result_chars => 'int', handoff_ms => 'num', handoff_headroom => 'num',
        reason => [enum => @HT_REASON], turn_id => 'hash', interjected => 'bool', compaction => 'bool',
        cache_read_share => 'num', result => 'word', calls => 'int', tokens => 'num', ms => 'num',
    },
    handoff_limit => { ht => 'hash', band => [enum => @BAND], calls => 'int', tokens => 'num' },
    handoff_race => { trigger => [enum => qw(auto)], draft => 'bool', published => 'bool', ht => 'hash' },
    handoff_user_interjected => { ht => 'hash' },
    # OT-1 / OT-4 (owner xxxxxxxx-06, 2026-10-22): the turn of a handoff-turn prompt a user turn
    # cancelled, aborted at its start (or the abort failed and it ran with no nudge; why
    # `rejected`, or `other-text` when the turn may carry another prompt too: REVIEW-NIGHT-3 R3-07)
    handoff_orphan_aborted => { turn_id => 'hash', ht => 'hash' },
    handoff_orphan_abort_failed => { turn_id => 'hash', ht => 'hash', why => [enum => qw(rejected other-text)] },
    handoff_mode => { mode => [enum => qw(private repo)], reason => 'word', declared => 'bool', accepted => 'bool' },
    idle_mismatch => { nonce => 'nonce' },
    # MG-3 / MG-5 (2026-10-23): the summarizer request's cache-read share, and a cold one (A-28)
    compaction_cache => { nonce => 'nonce', read_share => 'num' },
    compaction_cold => { nonce => 'nonce', read_share => 'num' },
    # ID-2 (2026-10-23): a native idle compaction no plugin dispatch shaped (A-29)
    idle_unshaped => { boundary_uuid => 'hash' },
    resume_remeasured => { nonce => 'nonce', age_s => 'num', ms => 'num' },
    # owner xxxxxxxx-37 (replaces ID-3's [idle-return] line): the idle block went again to a
    # person's return after a background result's turn took it; re-measured or not
    idle_return => { nonce => 'nonce', age_s => 'num', remeasured => 'bool' },
    # RP-2 (owner 2026-10-23, ratify xxxxxxxx#R3 overturned): a resume block over its soft 6,500 chars
    resume_block_over_soft => { nonce => 'nonce', chars => 'int' },
    resume_remeasure_failed => { nonce => 'nonce', age_s => 'num' },
    submit_dropped => { why => [enum => qw(session-changed)], site => [enum => qw(continue handoff-turn)] },
    queue_contract => { why => [enum => qw(untagged schema not-json exit timeout)] },
    handoff_export => { result => 'word', reason => 'word', bytes => 'int', rules => [list => 'word'] },
    relaunch_unmatched => { task_id => 'hash', origin_sid => 'hash', sha8 => 'drop' },
    jobs_caller_refused => { reason => 'word' },
    # SR-7 (2026-10-23): one `risk` call; the class ids only, never the command
    risk => { source => [enum => qw(own foreign)], result => [enum => qw(none ask)], classes => [list => 'word'] },
    queue_add => { result => 'word', exit => 'int', ms => 'num' },
    resume_receipt => { relation => 'word', tier => 'word', calls => 'int', drift => [list => 'word'],
                        bg => [counts => 'word'], questions => 'int', adopt => 'word', cmds_asked => 'int',
                        # SR-8 (2026-10-23): handoff commands run unasked; scoped approvals carried / used / asked
                        cmds_run => 'int', approvals_carried => 'int', approvals_used => 'int', approvals_asked => 'int' },
    heal => { origin_sid => 'hash', item => 'hash', result => [pre => [qw(ok)], [qw(ok REFUSED)]], bumped => 'bool', count => 'int',
              verdict => 'word', confidence => 'word', effects => 'word', signals => [counts => 'word'],
              mode => 'word', new_task_id => 'hash', prod_class => 'word',
              # HC-1 (2026-10-23): a recorded job, or an own handoff's recipe
              run_source => [enum => qw(recorded handoff)] },
    alert => { alert_id => 'word', rule => 'rule', severity => [enum => @SEVERITY],
               key => [obj => { session_id => 'hash', actor => 'actor', compaction_seq => 'int', nonce => 'nonce' }],
               evidence => [obj => {
                   line => 'int', count => 'int', calls => 'int', class => 'word', call_no => 'int', after => 'word',
                   args_present => 'bool', failed => 'word', verdict => [enum => @VERDICT], channel => [enum => @CHANNEL],
                   join => 'word', copy => 'word', scope_found => [enum => qw(main sub manual)], file => 'hash',
                   fabricated_check_tokens => 'int', measured => 'bool', band_position => 'word', tokens_before => 'num',
                   target => 'num', soft_max => 'num', native_trigger => 'num', source => 'word', warm_gap_s => 'num',
                   rapid_refill_run => 'int', turns_since_prev => 'int', bypass_suspected => 'bool', main => 'bool',
                   mod_off => 'bool', trigger_unknown => 'bool', arm_fp => 'hash', continue_after_halt_cond => 'bool',
                   cap => 'int', continues_last_hour => 'int', continue_without_nudge => 'bool', result => 'word',
                   relation => 'word', native_thrash => 'bool', mod_thrash => 'bool', batches => 'int',
                   lost_U => 'int', lost_D => 'int', lost_X => 'int', rules => [list => 'word'], hard => 'bool',
                   chars => 'int', growth => 'num', mb => 'num', kind => 'word', read_share => 'num' }],
    },
    watch_error => { stage => 'word', error_class => 'word' },
    # --- other rows of MOD-SPEC (kebab-case there, snake_case on disk) and of the built code ---
    bypass_suspected => { nonce => 'nonce', causes => [list => 'word'] },
    mod_off => { nonce => 'nonce' },
    compaction_unresolved => { nonce => 'nonce', trigger => [enum => @TRIGGER], channel => [enum => @CHANNEL] },
    copy_deferred => { nonce => 'nonce', id6 => 'id6', why => 'word' },
    copy_late => { nonce => 'nonce', id6 => 'id6', rel_path => 'slot' },
    copy_exists => { nonce => 'nonce' },
    copy_failed => { nonce => 'nonce', reason => 'word' },
    copy_mismatch => { nonce => 'nonce' },
    checkpoint => { nonce => 'nonce', ms => 'num', bytes => 'int', measured => 'bool', consent => 'word' },
    config_effective => { window => 'num', native_offset => 'num', native_trigger => 'num', reserve => 'num',
                          soft_max => 'num', target => 'num', disabled => 'word', clamped => [list => 'word'],
                          min_window => [or => 'num', 'never'], small_window => 'bool', soft_max_raw => 'num', target_raw => 'num' },
    config_clamped => { key => 'word', configured => 'num', effective => 'num' },
    config_invalid => { key => 'word', index => 'int' },
    # U-06 (lib/userre.pm): one of the user's own patterns stopped at its time bound, by key and position
    regex_timeout => { key => 'word', index => 'int', why => [enum => qw(timeout load budget error)] },
    config_ambiguous => { candidates => 'int' },
    continue_capped => { continues_last_hour => 'int' },
    decl_unknown_keys => { keys => 'drop' },
    halt => { reason => 'word', active => 'bool', was => 'bool' },
    helper_missing => {},
    keyset_change => { surface => 'word', keyset_sha8 => 'hex8', keys => 'drop' },
    lane_unknown => { why => 'word' },
    layers_missing => { id6 => 'id6', trigger => [enum => @TRIGGER] },
    lock_stale => { lock => 'word', reason => 'word' },
    measure => { bytes => 'int', ms => 'num', brief => 'bool' },
    # AP-5 (2026-10-23): approvals a measure found checked (handoff or summary); counts and class ids only;
    # origins (owner xxxxxxxx-12 "Count, log origin"): the carried ones by the origin kind of the row
    # their quote was found in
    approvals_carry => { source => [enum => qw(handoff summary)], checked => 'int', gate => 'int', unchecked => 'int', unverified => 'int', classes => [list => 'word'],
                         origins => [counts => [enum => qw(human composer bridge sdk none dialog unknown)]] },
    mod_outcome => { nonce => 'nonce', nudged => 'bool', continued => 'bool', halt => 'word', resume => 'word' },
    order_anomaly => { id6 => 'id6', nonce => 'nonce', uuid => 'hash', kind => 'word' },
    policy => { mods_managed_only => 'bool', hooks_managed_only => 'bool' },
    precompact_fallback => { nonce => 'nonce', trigger => [enum => qw(auto manual)] },
    precompact_marker_orphan => { nonce => 'nonce', trigger => [enum => qw(auto manual)] },
    precompact_shaped => { nonce => 'nonce', trigger => [enum => qw(auto manual)] },
    precompute_dispatched => { nonce => 'nonce' },
    precompute_not_reused => { nonce => 'nonce' },
    precompute_or_failed => { nonce => 'nonce', trigger => [enum => @TRIGGER] },
    repo_gitignore_drift => { root => 'drop' },
    repo_root_ignored => { root => 'drop' },
    resume_undelivered => { nonce => 'nonce', resume_pref => [enum => @CHANNEL] },
    root_in_git => { root => 'drop' },
    scope_leak => { nonce => 'nonce', scope => [enum => qw(main sub manual)], marker_scope => [enum => qw(main sub manual)] },
    self_call_hook_ran => { nonce => 'nonce' },
    sessionstart_ambiguous => { candidates => 'int', nonce => 'nonce' },
    skip => { why => 'word', ht => 'hash' },
    smoke_fail => { check => 'word', version => 'version' },
    smoke_pass => { version => 'version' },
    sweep_evidence => { copied => 'int', dup => 'int', ref_only => 'int', redacted => 'int', withheld => 'int', ms => 'num' },
    sweep_partial => { file => 'hash', reason => 'word' },
    test_mode => {},
    thrash => { compactions => 'int' },
    trigger_disabled_small_window => { target => 'num', window => 'num' },
    trigger_unknown => { trigger => 'word' },
    triggers_off => {},
    verdict => { nonce => 'nonce', verdict => [enum => @VERDICT] },
    verdict_mismatch => { nonce => 'nonce', postcompact => [enum => @VERDICT], after_step => [enum => @VERDICT] },
    version_change => { from => 'version', to => 'version' },
    version_hint => { from => 'version', to => 'version' },
    warn_quota => { bucket => 'hash', mb => 'num', quota_mb => 'num' },
    watch_prune => { days => 'int', files => 'int', bytes => 'int', sessions => 'int', kept => 'int' },
    project_copy => { result => 'word', mode => 'word' },
    project_init => { result => 'word' },
    notice => { id => 'word', result => [enum => qw(show seen)] },
    report_withheld => { reason => [enum => qw(identity secret)], file_kind => 'word' },
);

sub schema { return \%SCHEMA }

# RS-3 (owner xxxxxxxx-19, 2026-10-23: summaries opt-in per report, asked each time) and RS-5
# (owner xxxxxxxx-33, "Also handoffs": a second, separate yes): the file kinds that hold session
# text. A `summaries/<12 hex>.md` entry is allowed only in a bundle whose manifest says
# `with_summaries: true`, a `handoffs/<12 hex>.md` entry only with `with_handoffs: true` (the user
# said yes to that kind, `report --with-summaries` / `--with-handoffs`, in that run); `report
# verify` fails any other bundle that has one.
our @CONTENT_KINDS = qw(summaries handoffs);
our %CONTENT = (
    summaries => { re => qr{\Asummaries/[0-9a-f]{12}\.md\z}, flag => 'with_summaries' },
    handoffs  => { re => qr{\Ahandoffs/[0-9a-f]{12}\.md\z}, flag => 'with_handoffs' },
);
# content_kind(zip name) -> `summaries`, `handoffs` or undef.
sub content_kind {
    my ($name) = @_;
    return undef unless defined $name && !ref $name;
    for my $k (@CONTENT_KINDS) { return $k if $name =~ $CONTENT{$k}{re} }
    return undef;
}
# content_allowed(manifest, kind): the manifest flag of that kind is true, in a manifest as built
# (\1) or as decoded (watch::json: 1).
sub content_allowed {
    my ($m, $kind) = @_;
    my $f = $CONTENT{ $kind // '' } or return 0;
    my $v = ref $m eq 'HASH' ? $m->{ $f->{flag} } : undef;
    return 0 unless defined $v;
    return ref $v eq 'SCALAR' ? ($$v ? 1 : 0) : (!ref $v && $v eq '1') ? 1 : 0;
}

# Owner xxxxxxxx-34 ("Stable section ids", 2026-10-23): from spec_version 2 a handoff section is
# exported by its fixed id (`main:next-steps`), from the spec's `section_ids`, never by its
# position (`main:3`, spec_version 1), so a section added, moved or renamed never shifts another
# one's id. The manifest says `spec_version`; `report verify` refuses a bundle whose rows hold
# the other form (the two never mix).
our $SECTION_ID_RE = qr/\A(?:main|sub):[a-z][a-z-]{0,31}\z/;
our @SECTION_KEEP = qw(preamble other);
# The fields of the `heading` class: {ev => [[field, how]]}, how `key` (a counts object's keys)
# or `value` (the value, or each item of a list).
sub heading_fields {
    my %o;
    for my $ev (sort keys %SCHEMA) {
        for my $f (sort keys %{ $SCHEMA{$ev} }) {
            my $c = $SCHEMA{$ev}{$f};
            if (!ref $c) { push @{ $o{$ev} }, [ $f, 'value' ] if $c eq 'heading'; next }
            next unless ref $c eq 'ARRAY' && defined $c->[1] && !ref $c->[1] && $c->[1] eq 'heading';
            push @{ $o{$ev} }, [ $f, 'key' ] if $c->[0] eq 'counts';
            push @{ $o{$ev} }, [ $f, 'value' ] if $c->[0] eq 'list';
        }
    }
    return \%o;
}

1;

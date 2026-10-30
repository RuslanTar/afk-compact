package skills::approvals;
# lib/skills/approvals.pm: scoped approvals (spec §4 Approval (scoped), §8 approvals_checked,
# §15 approval-shape / approval-quote / approval-unchecked; SPEC-DELTAS AP-4, AP-5). Owner:
# WP-skills.
#
#   lint(\@lines, %a)          the publish checks; returns the ids whose quote passed
#   handoff_lines(doc, ctx, sid) the `Approvals (checked)` lines of `measure <handoff>`, and the
#                              `Approvals (context only, re-ask)` line
#   summary_lines(text, path)  the same for a compaction summary's copy (`measure --compact --copy`)
#   classes(entry)             the outward class ids an approval's action names, and its gate
#
# Quotes are checked in memory against the writing session's human-typed user rows and the
# user's answers in its AskUserQuestion dialogs (transcript::quotes_found; NR-14, owner
# xxxxxxxx-23: only the chosen label, the typed Other text, a note or a free-text response, never
# the question, an option description or any other tool output); no quote, action or target text
# is logged: rows carry counts and class ids only.
#
# Readings (REVIEW-NIGHT-2 §3; PROVISIONAL unless a ruling is named: owner decision open,
# recommended reading built):
#   O-3   decided (owner 2026-10-26 xxxxxxxx-09, "Quote src" Q-1 kept): code checks the quote
#         (this module at all);
#   O-1   only the own chain carries: a foreign handoff's approvals are never listed as checked;
#   O-12  decided (owner 2026-10-23 xxxxxxxx-27 revised, "No: forks re-ask"): approvals carry only
#         from this session and its `clear` / `handoff-resume` predecessors (%CARRY_REASON); a
#         `fork` or `bg-copy` link, or any other, carries none, though such a predecessor stays own
#         for running commands (locate, heal-check);
#   O-2   decided (owner 2026-10-23 xxxxxxxx-28, "Named read carries"): an approval that names one
#         production read and its targets carries like a fresh yes, also under
#         `unattended_prod_reads: forbid`; a production write, or a production action that is not
#         one command of the read grammar (an allow list), is the prod-write gate
#         ($PROD_READ_CARRIES, _prod_read);
#   claim root reading 2026-10-23 (fail closed; owner 21:47 "1. OK"): once a session claimed an
#         ended predecessor (`.sessions/successors/<sid>.json`), that predecessor's handoffs dated
#         at or before the claim carry approvals only along the claimant's line, the ones dated
#         after it only along the predecessor's own (_claim_cut), and the resumed predecessor's
#         quote checks count only rows after the claim (quote_floor);
#   gates from text (owner xxxxxxxx-10 "Push names", 2026-10-26, confirmed "Keep all four":
#         all four kept as built, no longer provisional; NIGHT-REVIEW 3.4):
#         P-1 $ACTION_WORDS reads a plain-words action ("push feat/x") into outward class ids, and
#         a gate named in plain words counts beside a class pattern's hit (REVIEW-NIGHT-3 R3-02:
#         "push feat/x and deploy" never carries a deploy);
#         P-2 a push approval that names no branch is protected-push ($PUSH_UNNAMED_IS_GATE), as
#         `risk` counts an unknown push destination: "yes, push it" is re-asked after a
#         compaction; only a `branch <name>`, a `git push` refspec or a name right after "push"
#         names a branch, and only a name with a letter and a slash or a branch that exists in cwd
#         (_push_named, _branch_word; not `HEAD`, a number, a filler word, a tag, a command
#         substitution, a file path or a repo slug);
#         P-3 a local merge (not a merge request) whose words name a protected branch is
#         protected-push ("merge feat/x into main" is re-asked);
#         P-4 a name after its remote prefix counts as that branch (`team/release` is `release`);
#         the remote's default branch is protected, as in `risk` (spec §4 Explicit gate, §12
#         protected-push; not a reading);
#         owner xxxxxxxx-29: a branch in the user's add-only `protected_branches` setting is
#         protected too (beside the shipped list, never instead of it);
#   quotes (transcript::quotes_found): owner xxxxxxxx-09 "Quote src" (2026-10-26) kept all four
#         rules as built, no longer provisional: Q-1 code checks the quote (O-3, this module at
#         all), Q-2 a message holding an approval line was pasted and does not count, Q-3 rows of
#         another session do not count, Q-4 whole words only (R3-04); owner xxxxxxxx-06 "Matching
#         item": a quote under 4 words is the whole message, or one whole numbered line of it that
#         answers the one item of the closing list naming a target, or, when no numbered item of
#         the assistant text names one, itself holds an outward verb of the action or a target
#         (see transcript.pm "Matching item"); owner
#         xxxxxxxx-12 "Count, log origin": SDK-origin rows count as the user's words, and the
#         approvals_carry row counts the carried approvals by the origin of the row their quote
#         was found in (`origins`, class words only; publish keeps each checked id's origin in
#         its line-hash record so a handoff's carry can count it too).
#
# Line hashes (REVIEW-NIGHT-3 U3-01; root ruling 2026-10-23 11:56, a must-have before unattended
# use): publish records a SHA-256 of each checked `## Approvals` line, keyed by its id, in a
# plugin-owned record of the private store (`.sessions/approvals/<sid>.<nonce>.json`, never in
# the handoff file, never rewritten). Before any carry (`measure <handoff>`, which resume reads,
# and publish's own-chain carry) a checked id counts only when the file holds exactly one line
# with that id and the line's hash equals the record: an added line, an edited quote, action,
# target or id, a file with no record (published before the hashes) or a record without the id
# makes the line context only (re-ask).
#
# Plugin handoff turns (0.1.2 D-8): a handoff the plugin asked for (a stage bound to a handoff
# turn, `handoff_ht`: reasons halt, precompact and idle) records every own approval as context
# only, `U-n: approval "<words>" — action <what> · targets <…> ; context only, not valid here;
# re-ask` (approval_context_re), and its Next step re-asks. The auto-mode classifier blocked the
# Write of a usable approval in a handoff the user did not ask for (its carve-out for recording
# at the user's request cannot apply), and passed this shape (probe B, V3 0/9 blocked; X-5: no
# denial note on a usable line). lint(context_only => 1) blocks any other own line
# (`approval-plugin-turn`, also for a second line with one id or a new approval line outside the
# section: review finding 4) and still checks the quote; publish then lists no id in
# approvals_checked, records no line hashes and writes `requested_by: plugin` (AC-4), so nothing
# in the file can carry. The same context-only line is accepted in any stage (never checked,
# never carried), and `measure` lists such lines as context only: `(plugin handoff)` in a file
# marked requested_by: plugin, where no line carries at all, else `(written as context)`.
#
# The question (0.1.2 HL-2, X-2): after the words, `(answer to "<question>")` may keep the
# question a short answer replies to; the quote check reads the words only. Only a handoff the
# user asked for may hold it (a plugin handoff turn writes the bare V3 shape). Denied actions
# (AC-2, mitigation 1): see _denied below; a denial note sits only on a context-only line (X-5).
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::spec;
use skills::core;
use skills::ctx;
use skills::store;
use skills::gitfacts;

our $HEADING = '## Approvals';
# Lineage links approvals carry over (owner 2026-10-23 xxxxxxxx-27 revised, "No: forks re-ask"):
# a fork's or bg copy's predecessor, and a link of any other or unknown kind, carries none.
# SessionStart writes `clear` and `fork` links (sessions::write_lineage); `pin --resumed-from`
# writes the `handoff-resume` link (skills::session_cmds::link_resume, review of bcdaca6) only
# for a fresh session with no link yet that resumes the newest handoff of an ended predecessor
# with no carrying successor, after claiming that predecessor by exclusive create
# (`.sessions/successors/<sid>.json`, claim_path), so one handoff never lends its `once`
# approvals to two sessions.
our %CARRY_REASON = map { $_ => 1 } qw(clear handoff-resume);
our $SUCCESSORS_DIR = 'successors';           # under <handoff_root>/.sessions/
# Production (owner 2026-10-23 xxxxxxxx-28, "Named read carries. forbid setting is default rule,
# but user explicit ask/approval always wins"): an approval whose action or targets match a
# production class is the prod-write gate (re-asked) unless it is one production read by an allow
# list (re-review of the PR-28 build: a list of refused separators and write words let an action
# with an unlisted separator, or none, read as a read):
#   - its action, after one pair of quotes or backticks around the whole of it is dropped, is
#     plain ASCII words of $PROD_READ_WORD_RE separated by spaces (no shell control, separator,
#     redirect, substitution, quote, glob, home or root path, newline, other space or look-alike
#     letter, and no word that ends a sentence or clause: `prod.`, `prod,`), none a clause word
#     (%PROD_CLAUSE_WORDS), and those words are exactly one command of the read grammar:
#     `kubectl` with a subcommand of %KUBECTL_READ first, at most %KUBECTL_ARGS operands and only
#     the flags of %KUBECTL_FLAGS (never a secret), `helm` with a subcommand of %HELM_READ first
#     and only the flags of %HELM_FLAGS, or a readonly_cmd_re command (the spec's local read-only
#     commands, whose extra words stay operands of a read);
#   - every target is `<identity> @ <state>` (or one `lane:` word) in plain ASCII words of
#     $PROD_TARGET_WORD_RE, at most $PROD_TARGET_WORDS words on each side, none a clause word
#     (%PROD_CLAUSE_WORDS);
#   - no outward class, plain outward word or write word ($PROD_WRITE_WORDS, risk.pm
#     $PROD_WRITE_RE) appears in its action or targets.
# Such a read carries like any checked approval, also under `unattended_prod_reads: forbid`
# (resume R7). Anything else that names production, a read told in plain words included, stays a
# gate (fail closed). 0 restores "every production approval is a gate".
our $PROD_READ_CARRIES = 1;
our $PROD_READ_WORD_RE = qr/\A[A-Za-z0-9_.\/:=,-]*[A-Za-z0-9_\/-]\z/;
# A positional word of a kubectl or helm read (a resource, a name, a release): starts with a
# letter or a digit, so it is never a flag, a root path or a home path.
our $PROD_READ_ARG_RE = qr/\A[A-Za-z0-9][A-Za-z0-9_.\/:,-]*\z/;
# A flag's value (`-l app=api,tier=web`, `--field-selector=status.phase=Running`): the same, `=` too.
our $PROD_READ_VAL_RE = qr/\A[A-Za-z0-9][A-Za-z0-9_.\/:=,-]*\z/;
our %KUBECTL_READ = map { $_ => 1 } qw(get describe logs top explain version api-resources);
# The most operands each takes (a type and a name; a pod and a container; one field path).
our %KUBECTL_ARGS = (get => 2, describe => 2, logs => 2, top => 2, explain => 1, version => 0, 'api-resources' => 0);
# Flags: 1 takes a value (`-n prod`, `-n=prod`, `--namespace=prod`), 0 takes none, a hash ref
# takes one of its values (`-o wide`, `-owide`). No flag names a file, a server, a token or
# another user, and none follows or watches.
our %KUBECTL_FLAGS = (
    '-n' => 1, '--namespace' => 1, '--context' => 1, '-l' => 1, '--selector' => 1, '--field-selector' => 1,
    '-c' => 1, '--container' => 1, '--tail' => 1, '--since' => 1,
    '-o' => { map { $_ => 1 } qw(wide name json yaml) }, '--output' => { map { $_ => 1 } qw(wide name json yaml) },
    '-A' => 0, '--all-namespaces' => 0, '--show-labels' => 0, '--no-headers' => 0, '--show-kind' => 0,
    '-p' => 0, '--previous' => 0, '--timestamps' => 0, '--all-containers' => 0, '--client' => 0,
);
our %KUBECTL_TOP = map { $_ => 1 } qw(pod pods po node nodes no);
our %HELM_READ = map { $_ => 1 } qw(list ls status get history);
our %HELM_GET = map { $_ => 1 } qw(all values manifest notes hooks metadata);
our %HELM_FLAGS = (
    '-n' => 1, '--namespace' => 1, '--kube-context' => 1, '--revision' => 1, '--max' => 1,
    '-o' => { map { $_ => 1 } qw(table json yaml) }, '--output' => { map { $_ => 1 } qw(table json yaml) },
    '-a' => 0, '--all' => 0, '-A' => 0, '--all-namespaces' => 0, '-q' => 0, '--short' => 0,
);
our $PROD_TARGET_WORD_RE = qr/\A[A-Za-z0-9_.\/:=!#+-]+\z/;
our $PROD_TARGET_WORDS = 4;
# Words that join a second step or tell a sentence, never an operand of a read.
our %PROD_CLAUSE_WORDS = map { $_ => 1 } qw(and then also plus or after afterwards before so to while if when unless until
    with via using by once xargs tee the a an it them this that);
our $PROD_WRITE_WORDS = qr/\b(?:fix|change|edit|set|add|remove|enable|disable|rotate|trigger|kill|stop|start|roll[ -]?back|promote|purge|flush|clear|backfill|import|load|sync|send|run|execute|migrat\w*|release|upgrade|downgrade|install|uninstall|drain|cordon|evict|terminate|reboot|shutdown|resize|approve|close|archive|tag|label|annotate|scp|rsync)\b/i;
# Owner xxxxxxxx-10 "Push names" (P-2 kept, confirmed "Keep all four"): a push approval that
# names no branch is protected-push. Only these name a branch (_push_named): a `branch <name>`
# target or phrase, a refspec of a `git push` command (either side of `src:dst`), or in plain
# words a name right after "push" ($PUSH_FILLER words aside), each only when the name has a
# slash (`feat/x`) or is a branch that exists in cwd (_branch_word). `HEAD`, `@`, a number ("push
# 2 commits"), a hyphenated word that is no branch ("push the follow-up fix"), a stop word ("push
# this branch to origin"), a tag (`v1.2.0`, "the tag", `--tags`), a command substitution or
# variable in a `git push`, a file name (`app/retry.rb`), a path that exists in cwd and a word in
# any other target (a file path, an `owner/repo` slug) name none.
our $PUSH_UNNAMED_IS_GATE = 1;
our $PUSH_FILLER = qr/\A(?:the|branch|to|up|on|onto|into)\z/i;
# Words after "branch" (or "push") that are never a branch name.
our %BRANCH_STOP = map { $_ => 1 } qw(a an the to up and of on onto into in at for from with by as
    it its this that these those my your our their i now then here there current same new old
    other remote local origin upstream is was be name named called first next last);
# A tag-shaped name (`v1.2.0`, `1.2`, `v2`): a tag push names no branch.
our $TAG_NAME = qr/\A[vV]?[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?\z/;
# A tag push in words or flags: `--tags`, `--follow-tags`, `refs/tags/`, or the word "tag" or
# "tags" (not inside a name such as `fix/tag-parser`).
our $PUSH_TAG = qr/--(?:follow-)?tags\b|\brefs\/tags\/|(?<![\w\/-])tags?(?![\w\/-])/i;
# The origin class words the approvals_carry row counts (owner xxxxxxxx-12); anything else is
# `unknown` (a line carried from a record written before the origins were kept).
our %ORIGIN_WORDS = map { $_ => 1 } qw(human composer bridge sdk none dialog unknown);
our $ENTRY_MAX = 160;
our $HASH_DIR = 'approvals';                 # under <handoff_root>/.sessions/
my $NONCE_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;
our %HASH_WHY = (unhashed => 'no hash recorded', missing => 'not in the publish record', changed => 'changed since publish');
# Plain words of an action, read as outward class ids when no class pattern matched the text.
our @ACTION_WORDS = (
    [ 'force-push', qr/\bforce[- ]?push|--force\b/i ],
    [ 'push', qr/\bpush/i ],
    [ 'mr-write', qr/\b(?:merge|pull)[- ]request|\b(?:MR|PR)s?\b|![0-9]+/ ],
    [ 'publish', qr/\bpublish|\brelease\b/i ],
    [ 'deploy', qr/\bdeploy|\broll[- ]?out\b/i ],
    [ 'env-write', qr/\bsecrets?\b|\benv(?:ironment)?[- ]var|\bconfig[- ]var/i ],
    # Any kubectl or helm action is infrastructure work, except an action that is exactly one
    # read command of the read grammar (_tool_read in classes; owner xxxxxxxx-28, owner 2026-10-23
    # 21:47 "1. OK": a READ subcommand is no infra-write gate in any environment).
    [ 'infra-write', qr/\bterraform|\btofu\b|\bpulumi|\bkubectl|\bhelm\b|\binfra(?:structure)?\b/i ],
    [ 'history-rewrite', qr/\brebase|\bamend|\bsquash|reset --hard/i ],
    [ 'recursive-delete', qr/\bdelete|\bwipe|\bdrop\b|\brm -r/i ],
    [ 'http-write', qr/\b(?:POST|PUT|PATCH|DELETE)\b|\bwebhook/ ],
);
# The infra-write plain words other than the two tools _tool_read may exempt.
my $INFRA_OTHER_RE = qr/\bterraform|\btofu\b|\bpulumi|\binfra(?:structure)?\b/i;
my $LINE_RE = qr/\bU-[0-9]+:\s*approval\b/;
# A scope or state field of approval_re, which a context-only line never holds.
my $STATE_WORDS = qr/·[ \t]*(?:once|standing)\b|\bnot yet used\b|\bused[ \t]+[0-9]{4}-[0-9]{2}-[0-9]{2}\b/;
# Loose form for compaction summaries (the summary writes several on one line or a list).
my $LOOSE_RE = qr/U-([0-9]+):?[ \t]+approval[ \t]+"([^"]+)"[ \t]+—[ \t]+action[ \t]+(.+?)[ \t]+·[ \t]+targets[ \t]+(.+?)[ \t]+·[ \t]+(once|standing(?:[ \t]*\([^)]*\))?)[ \t]+·[ \t]+(not yet used|used[ \t]+[0-9]{4}-[0-9]{2}-[0-9]{2}[ \t]+[0-9]{2}:[0-9]{2}(?:[ \t]+[+-][0-9]{4})?)/;

# The spec knows the section (a spec older than AP-3 has no approvals: nothing is checked).
sub enabled {
    return 0 unless eval { skills::spec::need('approval_re'); 1 };
    my $ids = skills::spec::lint_ids();
    return 0 unless $ids->{blocking}{'approval-shape'} && $ids->{blocking}{'approval-quote'} && $ids->{advisory}{'approval-unchecked'};
    return (grep { $_->{literal} eq $HEADING } @{ skills::spec::sections_main() }) ? 1 : 0;
}

sub is_approval_line { my ($l) = @_; return defined $l && $l =~ $LINE_RE ? 1 : 0 }

# parse_line(line) -> {n, id, quote, action, targets => [..], targets_text, scope, state, used}
# for a line in the spec's approval_re form, else undef.
sub parse_line {
    my ($l) = @_;
    my $re = skills::spec::regex_at('approval_re') or return undef;
    return undef unless defined $l && $l =~ $re;
    my %e = (n => $1, quote => $2, action => $3, targets_text => $4, scope => $5, state => $7);
    $e{id} = "U-$e{n}";
    return _finish(\%e);
}

# parse_context_line(line) -> {n, id, quote, action, targets => [..], targets_text, context => 1,
# question => 0|1, denied => 0|1} for an own line in the spec's approval_context_re form (no
# once/standing, no state; optionally the question the words answer and, in a handoff the user
# asked for, a ` · denied <how> <stamp>` note), else undef. A line whose targets still hold a
# scope or state word is no context line.
sub parse_context_line {
    my ($l) = @_;
    my $re = skills::spec::regex_at('approval_context_re') or return undef;
    return undef unless defined $l && $l =~ $re;
    my %e = (n => $1, quote => $2, question => (defined $3 ? 1 : 0), action => $4, targets_text => $5,
             denied => (defined $6 ? 1 : 0), scope => '', state => '', context => 1);
    return undef if "$e{action} · $e{targets_text}" =~ $STATE_WORDS;
    $e{id} = "U-$e{n}";
    return _finish(\%e);
}

# 1 when the spec has the context-only form and its lint id (0.1.2; an older spec has neither).
sub context_enabled {
    return 0 unless enabled() && defined skills::spec::regex_at('approval_context_re');
    return skills::spec::lint_ids()->{blocking}{'approval-plugin-turn'} ? 1 : 0;
}

# 1 when the spec has the denied-action rule (0.1.2 AC-2, mitigation 1).
sub denied_enabled { return context_enabled() && skills::spec::lint_ids()->{blocking}{'approval-denied'} ? 1 : 0 }

# Denied actions (0.1.2 AC-2, mitigation 1, in the owner's 0.1.2 scope of 2026-10-30): in a
# handoff the user asked for, a usable approval whose action a call of this session was refused
# for (the classifier, a deny rule or the user at the prompt; transcript::denied_calls) is
# blocked (`approval-denied`): it is written context only with its denial note, and its Next
# step asks.
# A denied call covers an approval when, in the approval's action and targets,
#   - a distinctive token of the call's input (a word with a digit or a `/ . : # ! @ _ -` inside:
#     a ticket key, a branch with a slash, a path or its file name, a URL) stands whole, or
#   - a service word of an MCP tool's server or name (not one of %DENY_STOP) stands as a word
#     (`mcp__…Atlassian…__editJiraIssue` names `atlassian`, `jira`), or
#   - the call names no such token and shares an outward class with the approval (a denied bare
#     `git push` covers every push approval).
# Fail closed: a wrong match costs one re-ask in the next session.
our %DENY_STOP = map { $_ => 1 } qw(mcp plugin claude server api app get set edit create update delete add remove write
    read list search find send post put patch fetch query run new the issue issues page pages comment comments
    message messages file files item items record records data info for and with tool tools);
my $DENY_TOKEN_SPLIT = qr/[\s"'`=,;()\[\]{}<>|&\\]+/;

sub _deny_keys {
    my ($c) = @_;
    my (%tok, %word, %cls);
    my $text = $c->{text} // '';
    for my $t (split $DENY_TOKEN_SPLIT, $text) {
        $t =~ s/[.:?]+\z//;
        next if length($t) < 3 || $t =~ /\A-/;
        # `\@` stays escaped: a bare `@_` in a class interpolates the sub's arguments (review
        # finding 1: `HASH(0x…)` made plain words distinctive, by memory address).
        next unless $t =~ /[A-Za-z0-9]{2}/ && $t =~ /[0-9\/.:#!\@_-]/;
        $tok{$t} = 1;
        # The file name of a path: copied out of $1 first, since the next match resets it
        # (review finding 2).
        if ($t =~ m{/([^/]{3,})\z}) {
            my $base = $1;
            $tok{$base} = 1 if $base =~ /[0-9.:#!\@_-]/ && $base =~ /[A-Za-z0-9]{2}/;
        }
    }
    my $tool = $c->{tool} // '';
    if ($tool =~ /\Amcp__(.+?)__(.+)\z/) {
        for my $w (map { lc } map { split /(?<=[a-z0-9])(?=[A-Z])|[^A-Za-z0-9]+/ } $1, $2) {
            $word{$w} = 1 if length($w) >= 3 && $w =~ /[a-z]/ && !$DENY_STOP{$w};
        }
    }
    for my $k (@{ (eval { skills::spec::outward_classes() }) || [] }) {
        $cls{ $k->{class} } = 1 if $tool =~ $k->{re} || ($tool eq 'Bash' && $text =~ $k->{re});
    }
    if ($tool eq 'Bash') { for my $w (@ACTION_WORDS) { $cls{ $w->[0] } = 1 if $text =~ $w->[1] } }
    return { tok => [ sort keys %tok ], word => [ sort keys %word ], cls => \%cls };
}

# _denied(entry, [deny keys…]) -> 1 when a denied call covers the approval (see above).
sub _denied {
    my ($e, $keys) = @_;
    my $text = "$e->{action} · $e->{targets_text}";
    my $lc = lc $text;
    my $ecls;
    for my $k (@{ $keys || [] }) {
        for my $t (@{ $k->{tok} }) { return 1 if $text =~ /(?<![\w.\/-])\Q$t\E(?![\w\/-]|\.\w)/ }
        for my $w (@{ $k->{word} }) { return 1 if $lc =~ /(?<![a-z0-9])\Q$w\E(?![a-z0-9])/ }
        next if @{ $k->{tok} } || !%{ $k->{cls} };
        $ecls //= do {
            my %h = map { $_ => 1 } @{ classes($e)->{outward} };
            for my $w (@ACTION_WORDS) { $h{ $w->[0] } = 1 if $e->{action} =~ $w->[1] }
            \%h;
        };
        return 1 if grep { $ecls->{$_} } keys %{ $k->{cls} };
    }
    return 0;
}

sub _finish {
    my ($e) = @_;
    $e->{targets} = [ grep { /\S/ } map { s/\A\s+|\s+\z//gr } split /,\s+/, $e->{targets_text} ];
    $e->{used} = $e->{state} =~ /\Aused\b/ ? 1 : 0;
    $e->{standing} = $e->{scope} =~ /\Astanding\b/ ? 1 : 0;
    return $e;
}

# section_lines(\@lines) -> {index => 1} for the body lines of `## Approvals`.
sub section_lines {
    my ($lines) = @_;
    my (%in, $on);
    for my $i (0 .. $#$lines) {
        my $l = $lines->[$i];
        if ($l =~ /\A##\s/ && $l !~ /\A###/) { $on = ($l =~ /\A\Q$HEADING\E\s*\z/) ? 1 : 0; next }
        $in{$i} = 1 if $on;
    }
    return \%in;
}

# classes(entry [, cwd]) -> {outward => [class ids], gate => gate id | undef}
# The outward ids are the class patterns' hits on the action and targets, else the plain
# words' ($ACTION_WORDS). The gate is read from both (REVIEW-NIGHT-3 R3-02: "git push origin
# feat/x and deploy" names a deploy although a class pattern matched the push). A push, or a
# local merge (not a merge request), whose words name a protected branch is protected-push:
# protected_branch_re, an entry of the user's protected_branches setting (owner xxxxxxxx-29,
# add-only) or the remote default branch of origin or upstream in cwd, each side of a `src:dst`
# refspec and a name after its remote prefix (`fork/main`) counted. Owner-ruled (xxxxxxxx-10
# "Push names", all four kept; see the header): P-1 to P-4; what names a branch for P-2:
# _push_named.
sub classes {
    my ($e, $cwd) = @_;
    my $text = "$e->{action} · $e->{targets_text}";
    my (@ids, %seen, %word);
    for my $c (@{ (eval { skills::spec::outward_classes() }) || [] }) {
        push @ids, $c->{class} if $text =~ $c->{re} && !$seen{ $c->{class} }++;
    }
    for my $w (@ACTION_WORDS) { $word{ $w->[0] } = 1 if $e->{action} =~ $w->[1] }
    # One kubectl or helm read command is no infrastructure work, in any environment (review of
    # slice A: a whole-command parse, not a look at the word after the tool).
    delete $word{'infra-write'} if $word{'infra-write'} && $e->{action} !~ $INFRA_OTHER_RE && _tool_read($e->{action});
    if (!@ids) {
        for my $w (@ACTION_WORDS) { push @ids, $w->[0] if $word{ $w->[0] } && !$seen{ $w->[0] }++ }
    }
    push @ids, 'push' if $seen{'force-push'} && !$seen{push}++;
    my %any = (%seen, %word);
    $any{push} = 1 if $any{'force-push'};
    my %gates = map { $_ => 1 } @{ (eval { skills::spec::get(q(explicit_gate_classes)) }) || [] };
    my ($gate) = grep { $gates{$_} } @ids, (grep { $word{$_} } map { $_->[0] } @ACTION_WORDS);
    # Production (owner xxxxxxxx-28): one named read carries; a write or an unclear action is the
    # prod-write gate.
    my $prod;
    my $pp = skills::core::prod();
    if (defined &settings::prod_class) { $prod = 'write' if defined settings::prod_class($text, $pp) }    # U-06: time-bound
    else {
        for my $c (@{ ref $pp->{classes} eq 'ARRAY' ? $pp->{classes} : [] }) {
            next unless ref $c eq 'HASH' && defined $c->{re};
            if ($text =~ $c->{re}) { $prod = 'write'; last }
        }
    }
    if (defined $prod && !defined $gate) {
        if ($PROD_READ_CARRIES && _prod_read($e, $text, \%any)) { $prod = 'read' }
        else { $gate = 'prod-write' }
    }
    my $merge = $e->{action} =~ /\bmerge\b/i && !$any{'mr-write'};
    if (!defined $gate && ($any{push} || $merge)) {
        my $pre = skills::spec::regex_at('protected_branch_re');
        my $pb = skills::core::protected();
        my %def = map { $_ => 1 } _default_branches($cwd);
        my $protected = 0;
        for my $t (@{ $e->{targets} }, $e->{action}) {
            my $id = $t =~ s/\s+@\s.*\z//sr;
            for my $w (split /[\s`'"]+/, $id) {
                # Sentence marks around a name ("to main!", "(main)", "main/"); a `:` inside
                # stays the refspec split below.
                $w =~ s/[.,;:!?)\]>\/]+\z//;
                $w =~ s/\A[(\[<]+//;
                next if $w eq '';
                for my $part (split /:/, $w) {
                    my $b = $part =~ s{\A\+}{}r;
                    $b =~ s{\Arefs/(?:heads|remotes)/}{};
                    for my $n ($b, ($b =~ m{\A[^/]+/(.+)\z} ? $1 : ())) {
                        $protected = 1 if ($pre && lc($n) =~ $pre) || $def{$n} || defined skills::core::protected_user($n, $pb);
                    }
                }
            }
        }
        $gate = 'protected-push' if $protected || ($any{push} && $PUSH_UNNAMED_IS_GATE && !_push_named($e, $cwd));
    }
    return { outward => \@ids, gate => $gate, prod => $prod };
}

# _push_named(entry, cwd) -> 1 when a push approval names the branch it pushes (P-2; see
# $PUSH_UNNAMED_IS_GATE): a `branch <name>` in a target or the action, a refspec of a `git push`
# command, or in plain words a name right after "push", each only when _branch_word takes it.
# Fail closed: anything else names no branch, so the push is protected-push. A tag push names no
# branch; a `git push` whose words hold a command substitution or a variable (`$(…)`, a
# backtick, `$x`) names none (it pushes whatever the shell fills in, the checked-out branch too).
sub _push_named {
    my ($e, $cwd) = @_;
    return 0 if grep { ($_ // '') =~ $PUSH_TAG } @{ $e->{targets} }, $e->{action};
    for my $t (@{ $e->{targets} }, $e->{action}) {
        my $id = ($t // '') =~ s/\s+@\s.*\z//sr;
        while ($id =~ /\bbranch[ \t]+[`'"]?([^\s`'",;)]+)/gi) { return 1 if _branch_word($1, $cwd) }
    }
    my $act = $e->{action} // '';
    my $git = 0;
    for my $seg (split /&&|\|\||[;|\n]/, $act) {
        next unless $seg =~ /\bgit\b.*?\bpush\b(.*)\z/s;
        my $rest = $1;
        return 0 if $rest =~ /[\$`]/;
        $git = 1;
        my @w = grep { $_ ne '' } map { s/\A[`'"]+|[`'".,)]+\z//gr } split /\s+/, $rest;
        my ($remote, $take);
        for my $x (@w) {
            if ($take) { $take = 0; next }
            if ($x =~ /\A-/) { $take = 1 if $x =~ /\A(?:-o|--push-option|--repo|--receive-pack|--exec)\z/; next }
            if (!defined $remote) { $remote = $x; next }
            for my $side (split /:/, $x =~ s/\A\+//r) { return 1 if _branch_word($side, $cwd) }
        }
    }
    return 0 if $git;
    my @w = map { s/\A[`'"(]+|[`'".,;:!?)]+\z//gr } split /\s+/, $act;
    for my $i (0 .. $#w) {
        next unless $w[$i] =~ /\A(?:force-?)?push(?:ed|es|ing)?\z/i;
        my $j = $i + 1;
        $j++ while $j <= $#w && $w[$j] =~ $PUSH_FILLER;
        return 1 if $j <= $#w && _branch_word($w[$j], $cwd);
    }
    return 0;
}

# _branch_word(word, cwd) -> 1 when the word names a branch: ref characters only with at least
# one letter, and either a slash (`feat/x`, `team/feat-y`) or the name of a branch that exists
# in cwd (refs/heads/<w>, or refs/remotes/<remote>/<w>; _ref_names). Never `HEAD` or `@` (or
# `HEAD~1`), a stop word (%BRANCH_STOP: "push this branch to origin"), a tag-shaped name
# (`v1.2.0`, `1.2.0`), a file name with a letter extension or a path in cwd. With no cwd (or
# outside git) only a slash name counts.
sub _branch_word {
    my ($w, $cwd) = @_;
    $w //= '';
    $w =~ s{\Arefs/(?:heads|remotes)/}{};
    return 0 unless $w =~ m{\A[A-Za-z0-9_][A-Za-z0-9._/-]*\z} && $w !~ m{//|[/.]\z} && $w =~ /[A-Za-z]/;
    return 0 if $w =~ /\A(?:HEAD|@)(?:[~^].*)?\z/ || $w =~ /\.[A-Za-z][A-Za-z0-9]{0,5}\z/;
    return 0 if $BRANCH_STOP{ lc $w } || $w =~ $TAG_NAME;
    $cwd //= skills::util::cwd();
    return 0 if defined $cwd && -e "$cwd/$w";
    return 1 if $w =~ m{/};
    return _ref_names($cwd)->{$w} ? 1 : 0;
}

# The short names of the branches in cwd: each refs/heads/<w>, and <w> of each
# refs/remotes/<remote>/<w> ({} outside git or with no cwd).
my %REF_NAMES;
sub _ref_names {
    my ($cwd) = @_;
    return {} unless defined $cwd;
    $REF_NAMES{$cwd} //= do {
        my %n;
        my $r = eval { skills::gitfacts::git($cwd, 'for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/remotes') };
        if (ref $r eq 'HASH' && $r->{rc} == 0) {
            for my $l (split /\n/, $r->{out} // '') {
                if ($l =~ m{\Arefs/heads/(.+)\z}) { $n{$1} = 1 }
                elsif ($l =~ m{\Arefs/remotes/[^/]+/(.+)\z} && $1 ne 'HEAD') { $n{$1} = 1 }
            }
        }
        \%n;
    };
    return $REF_NAMES{$cwd};
}

# 1 when an approval that names production is one production read by the allow list above
# (owner xxxxxxxx-28; re-review of the PR-28 build): one command of the read grammar in plain
# words, targets of the `<identity> @ <state>` form, and no outward class, plain outward word or
# write word anywhere in its action or targets. Anything else is 0 (the prod-write gate).
sub _prod_read {
    my ($e, $text, $any) = @_;
    return 0 if %$any;
    my $act = $e->{action} // '';
    $act =~ s/\A +| +\z//g;
    $act = $2 if $act =~ /\A([`"'])(.*)\1\z/s;
    $act =~ s/\A +| +\z//g;
    my @w = split / +/, $act;
    return 0 unless @w && !grep { $_ !~ $PROD_READ_WORD_RE || $PROD_CLAUSE_WORDS{ lc $_ } } @w;
    my $cmd = shift @w;
    if ($cmd eq 'kubectl') { return 0 unless _kubectl_read(@w) }
    elsif ($cmd eq 'helm') { return 0 unless _helm_read(@w) }
    else {
        my $ro = skills::spec::regex_at('readonly_cmd_re');
        return 0 unless $ro && $act =~ $ro;
    }
    return 0 unless _prod_targets(@{ $e->{targets} || [] }) && @{ $e->{targets} || [] };
    require skills::risk;
    no warnings 'once';
    my $risk_write = $skills::risk::PROD_WRITE_RE;
    return 0 if $text =~ $PROD_WRITE_WORDS || !defined $risk_write || $text =~ $risk_write;
    return 1;
}

# 1 when an action is exactly one `kubectl` or `helm` command of the read grammar (_kubectl_read,
# _helm_read), in plain ASCII words of $PROD_READ_WORD_RE with no clause word, after one pair of
# quotes or backticks around the whole of it is dropped; the production rules for targets do not
# apply here. A hyphenated subcommand (`get-foo`), an unlisted subcommand or flag, or a second
# step is 0.
sub _tool_read {
    my ($action) = @_;
    my $act = $action // '';
    $act =~ s/\A +| +\z//g;
    $act = $2 if $act =~ /\A([`"'])(.*)\1\z/s;
    $act =~ s/\A +| +\z//g;
    my @w = split / +/, $act;
    return 0 unless @w && !grep { $_ !~ $PROD_READ_WORD_RE || $PROD_CLAUSE_WORDS{ lc $_ } } @w;
    my $cmd = shift @w;
    return $cmd eq 'kubectl' ? _kubectl_read(@w) : $cmd eq 'helm' ? _helm_read(@w) : 0;
}

# _read_words(\@words, \%flags) -> [subcommand, positional words…] | undef: the first word is the
# subcommand (as the infra-write plain word reads it: a flag before it is no read), every later
# word that starts with `-` a flag of %flags (with its value of $PROD_READ_VAL_RE, attached or
# next), every other one a positional word of $PROD_READ_ARG_RE; undef on anything else.
sub _read_words {
    my ($w, $flags) = @_;
    return undef unless @$w && $w->[0] =~ /\A[a-z][a-z-]*\z/;
    my @pos = ($w->[0]);
    for (my $i = 1; $i < @$w; $i++) {
        my $t = $w->[$i];
        if ($t !~ /\A-/) {
            return undef unless $t =~ $PROD_READ_ARG_RE;
            push @pos, $t;
            next;
        }
        my ($name, $val) = $t =~ /\A(--?[A-Za-z][A-Za-z-]*)=(.*)\z/s ? ($1, $2) : ($t, undef);
        ($name, $val) = ($1, $2) if !exists $flags->{$name} && $t =~ /\A(-o)([a-z]+)\z/ && exists $flags->{$1};
        return undef unless exists $flags->{$name};
        my $kind = $flags->{$name};
        if (!$kind) { return undef if defined $val; next }
        if (!defined $val) { return undef unless $i + 1 < @$w; $val = $w->[++$i] }
        return undef unless ref $kind ? $kind->{$val} : $val =~ $PROD_READ_VAL_RE;
    }
    return \@pos;
}

# The words after `kubectl`: one read subcommand of %KUBECTL_READ first, at most %KUBECTL_ARGS
# operands, no secret named, `top` only for pods or nodes.
sub _kubectl_read {
    my @w = @_;
    my $pos = _read_words(\@w, \%KUBECTL_FLAGS) or return 0;
    my ($sub, @args) = @$pos;
    return 0 unless defined $sub && $KUBECTL_READ{$sub} && @args <= ($KUBECTL_ARGS{$sub} // 0);
    return 0 if grep { /(?:\A|[,\/.])secrets?(?:\z|[,\/.])/i } @args;
    return 0 if $sub eq 'top' && !(@args && $KUBECTL_TOP{ $args[0] });
    return 1;
}

# The words after `helm`: one read subcommand of %HELM_READ first (`get` with a part of
# %HELM_GET), `list` with no operand, the others with one release name.
sub _helm_read {
    my @w = @_;
    my $pos = _read_words(\@w, \%HELM_FLAGS) or return 0;
    my ($sub, @args) = @$pos;
    return 0 unless defined $sub && $HELM_READ{$sub};
    if ($sub eq 'get') { my $part = shift @args; return 0 unless defined $part && $HELM_GET{$part} }
    return (@args == 0 ? 1 : 0) if $sub eq 'list' || $sub eq 'ls';
    return (@args == 1 ? 1 : 0);
}

# 1 when every target is `<identity> @ <state>` or one `lane:` word, in plain ASCII words of
# $PROD_TARGET_WORD_RE, at most $PROD_TARGET_WORDS on each side, with no clause word.
sub _prod_targets {
    my @t = @_;
    for my $t (@t) {
        next if $t =~ /\Alane:[A-Za-z0-9_.\/-]+\z/;
        my @sides = $t =~ /\A(.+?) @ (.+)\z/s or return 0;
        for my $side (@sides) {
            my @w = split / /, $side, -1;
            return 0 unless @w && @w <= $PROD_TARGET_WORDS;
            return 0 if grep { $_ !~ $PROD_TARGET_WORD_RE || $PROD_CLAUSE_WORDS{ lc $_ } } @w;
        }
    }
    return 1;
}

# The default branches of the remotes origin and upstream in cwd (refs/remotes/<r>/HEAD), the
# spec's "the remote's default branch" of protected-push; () outside git.
my %DEFAULT_BRANCHES;
sub _default_branches {
    my ($cwd) = @_;
    $cwd //= skills::util::cwd();
    return () unless defined $cwd;
    $DEFAULT_BRANCHES{$cwd} //= do {
        my @b;
        for my $r (qw(origin upstream)) {
            my $x = eval { skills::gitfacts::line(skills::gitfacts::git($cwd, 'symbolic-ref', '--short', '-q', "refs/remotes/$r/HEAD")) };
            push @b, $1 if defined $x && $x =~ m{\A\Q$r\E/(.+)\z};
        }
        \@b;
    };
    return @{ $DEFAULT_BRANCHES{$cwd} };
}

# lint(\@lines, prev_lines => {line => 1}, tag_re => qr, note => text,
#      chain => [{text, checked => {U-n => 1}}], transcript => path | undef,
#      quote_floor => [quote_floor(ctx, sid)], context_only => 1 | undef)
#   -> {blocking => [[rule, where]…], advisory => [...], checked => [U-n…], lines => n,
#       unchecked => n, context => n, classes => [outward ids of checked approvals],
#       origins => {U-n => origin class word} for the checked ids (owner xxxxxxxx-12)}
# context_only (a plugin handoff turn, 0.1.2 D-8): every own line must be the context-only form
# (approval-plugin-turn otherwise); its quote is still checked (approval-quote), and no id is
# returned as checked. Without it a context-only own line is accepted too, never checked, and a
# usable line whose action this session was refused for is `approval-denied` (AC-2; the
# transcript's denied calls, transcript::denied_calls, read in memory only).
sub lint {
    my ($lines, %a) = @_;
    my %r = (blocking => [], advisory => [], checked => [], lines => 0, unchecked => 0, context => 0, classes => [], origins => {});
    return \%r unless enabled();
    my $in = section_lines($lines);
    my ($tag_re, $note) = ($a{tag_re}, $a{note} // '');
    my $cx_ok = context_enabled();
    my $cx_only = $a{context_only} && $cx_ok ? 1 : 0;
    # In a plugin handoff turn every shape fault is reported as approval-plugin-turn, whose fix
    # names the context-only form (review finding 4: approval-shape's fix asks for once or
    # standing and a state, the opposite).
    my $shape = $cx_only ? 'approval-plugin-turn' : 'approval-shape';
    my $dn_ok = !$cx_only && denied_enabled();
    my @own;
    for my $i (0 .. $#$lines) {
        my $l = $lines->[$i];
        my $tagged = $tag_re && $l =~ $tag_re ? 1 : 0;
        my $where = 'line ' . ($i + 1);
        if (!$in->{$i}) {
            # An approval line outside the section: new ones are flagged; a line carried
            # byte-identical from the base or own file, or a tagged carried line, is context.
            push @{ $r{blocking} }, [ $shape, $where ] if is_approval_line($l) && !$tagged && !$a{prev_lines}{$l};
            next;
        }
        next unless $l =~ /\S/;
        $r{lines}++;
        if ($tagged) {
            # In a plugin handoff turn this is approval-plugin-turn too (review finding 7).
            push @{ $r{blocking} }, [ $shape, $where ] unless $l =~ $LINE_RE && $l =~ /"[^"]+"/ && index($l, $note) >= 0;
            next;
        }
        my $e;
        if ($cx_only) {
            # A plugin handoff turn: only the context-only form of the probe (V3): a usable line,
            # one with a scope or state word, one without the note, and one with the question or
            # a denial note are blocked (X-2: neither was probed on a plugin handoff).
            $e = parse_context_line($l);
            if (!$e || $e->{question} || $e->{denied}) { push @{ $r{blocking} }, [ 'approval-plugin-turn', $where ]; next }
        } else {
            $e = parse_line($l) // ($cx_ok ? parse_context_line($l) : undef);
            # A denial note on a line that is no context line: the action was denied, so the
            # line must be context only (X-5: never a denial note on a usable approval).
            if (!$e) { push @{ $r{blocking} }, [ ($dn_ok && $l =~ /\bdenied\b/i ? 'approval-denied' : 'approval-shape'), $where ]; next }
            # A usable line that parses with a denial note in its action, targets or after
            # `given` (review finding 6; the user's words and the question are not read).
            if ($dn_ok && !$e->{context}) {
                my $at = index($l, " — action $e->{action} · targets ");
                if ($at >= 0 && substr($l, $at) =~ /·\s*denied\b/i) { push @{ $r{blocking} }, [ 'approval-denied', $where ]; next }
            }
        }
        # One line per id (REVIEW-NIGHT-3 R3-05): approvals_checked lists ids, so a second line
        # with a checked line's id would ride on its check.
        if (grep { $_->{id} eq $e->{id} } @own) { push @{ $r{blocking} }, [ $shape, $where ]; next }
        $e->{where} = $where;
        push @own, $e;
    }
    # AC-2: a usable line whose action this session was refused for (see _denied).
    if ($dn_ok && grep { !$_->{context} } @own) {
        my $calls = defined $a{transcript} && defined &transcript::denied_calls ? transcript::denied_calls($a{transcript}) : undef;
        my @keys = map { _deny_keys($_) } @{ $calls || [] };
        if (@keys) {
            my @keep;
            for my $e (@own) {
                if (!$e->{context} && _denied($e, \@keys)) { push @{ $r{blocking} }, [ 'approval-denied', $e->{where} ]; next }
                push @keep, $e;
            }
            @own = @keep;
        }
    }
    my @ask;
    for my $e (@own) {
        if ($e->{context}) { if (_carried_context($e, $a{chain})) { $e->{ok} = 1; next } }
        elsif (my $d = _carried($e, $a{chain})) { $e->{ok} = 1; $e->{origin} = _origin_word($d->{origins}{ $e->{id} }); next }
        push @ask, $e;
    }
    if (@ask) {
        my ($fok, $floor) = ref $a{quote_floor} eq 'ARRAY' ? @{ $a{quote_floor} } : (1, undef);
        my @org;
        my $res = defined $a{transcript} && $fok
            ? skills::core::quotes_found($a{transcript}, [ map { _ask($_) } @ask ], $a{sid}, after => $floor, origins => \@org)
            : undef;
        for my $k (0 .. $#ask) {
            my $v = $res ? $res->[$k] : undef;
            if (!defined $v) { push @{ $r{advisory} }, [ 'approval-unchecked', $ask[$k]{where} ]; $r{unchecked}++ }
            elsif ($v) { $ask[$k]{ok} = 1; $ask[$k]{origin} = _origin_word($org[$k]) }
            else { push @{ $r{blocking} }, [ 'approval-quote', $ask[$k]{where} ] }
        }
    }
    my %cls;
    # A context-only line is never checked: it grants nothing, here or after a resume.
    $r{context} = scalar grep { $_->{context} } @own;
    for my $e (grep { $_->{ok} && !$_->{context} } @own) {
        push @{ $r{checked} }, $e->{id};
        $r{origins}{ $e->{id} } = $e->{origin} // 'unknown';
        $cls{$_} = 1 for @{ classes($e)->{outward} };
    }
    $r{classes} = [ sort keys %cls ];
    return \%r;
}

# One quote check's ask: the quote, the targets and the action (the matching-item rule reads the
# action's words; owner xxxxxxxx-06).
sub _ask { my ($e) = @_; return { quote => $e->{quote}, targets => $e->{targets}, action => $e->{action} } }

# An origin class word of %ORIGIN_WORDS, else `unknown`.
sub _origin_word { my ($w) = @_; return defined $w && !ref $w && $ORIGIN_WORDS{$w} ? $w : 'unknown' }

# {origin word => n} over a list of entries (their `origin`).
sub _origin_counts {
    my ($es) = @_;
    my %n;
    $n{ _origin_word($_->{origin}) }++ for @$es;
    return \%n;
}

# A line carried from an own-chain file that listed its id in approvals_checked: the same id,
# words, action, targets and once/standing; its state may go from `not yet used` to `used`.
# Returns that chain document (its `origins` name where the quote was found), else undef.
sub _carried {
    my ($e, $chain) = @_;
    for my $d (@{ $chain || [] }) {
        next unless $d->{checked}{ $e->{id} };
        for my $l (split /\n/, $d->{text} // '') {
            my $p = parse_line($l) or next;
            next unless $p->{id} eq $e->{id} && $p->{quote} eq $e->{quote} && $p->{action} eq $e->{action}
                && $p->{targets_text} eq $e->{targets_text} && $p->{scope} eq $e->{scope};
            return $d if $p->{state} eq 'not yet used' || $p->{state} eq $e->{state};
        }
    }
    return undef;
}

# A context-only line carried from an own-chain file: an own line of that file's `## Approvals`
# (untagged: another session's words carried there are never this chain's), in either form, with
# the same id, words, action and targets. Its quote was checked when that file was published,
# and a context-only line grants nothing, so the file need not list the id as checked.
sub _carried_context {
    my ($e, $chain) = @_;
    for my $d (@{ $chain || [] }) {
        for my $p (@{ _section_entries($d->{text}, 1) }) {
            return 1 if $p->{id} eq $e->{id} && $p->{quote} eq $e->{quote} && $p->{action} eq $e->{action}
                && $p->{targets_text} eq $e->{targets_text};
        }
    }
    return 0;
}

# The ids of a frontmatter approvals_checked value.
sub checked_ids {
    my ($v) = @_;
    return {} unless defined $v && !ref $v;
    return { map { $_ => 1 } grep { /\AU-[0-9]+\z/ } split /\s*,\s*/, $v };
}

# An own-chain document for the carry check: {text, checked, origins}; undef unless the file is own for
# this session by own_relation (REVIEW-NIGHT-3 R3-03: a fork's or bg-copy's base, an export, an
# imported copy or a file outside the store lends no checked approvals to the new handoff).
# Only checked ids whose line matches the publish record carry (U3-01).
sub chain_doc {
    my ($path, $ctx, $sid) = @_;
    return undef unless defined $path && -f $path;
    my $d = skills::store::read_doc($path) or return undef;
    my ($own) = own_relation($d, $ctx, $sid);
    return undef unless $own;
    my ($good) = verify_checked($ctx, $d, checked_ids($d->{fm}{approvals_checked}));
    return { text => $d->{body} // '', checked => $good, origins => origins_of($ctx, $d) };
}

# ---- line hashes (U3-01)

sub line_hash { my ($l) = @_; return skills::util::sha256_hex($l // '') }

# The record's path for a handoff's session_id and nonce, or undef (no store, a bad key).
sub hash_path {
    my ($ctx, $fm) = @_;
    return undef unless $ctx && defined $ctx->{root} && ref $fm eq 'HASH';
    my ($sid, $n) = ($fm->{session_id} // '', $fm->{nonce} // '');
    return undef unless skills::ctx::valid_sid($sid) && $n =~ $NONCE_RE;
    return "$ctx->{root}/.sessions/$HASH_DIR/$sid.$n.json";
}

# The parsed, untagged lines of a body's `## Approvals`, each with its exact text (with
# $context, the context-only own lines too).
sub _section_entries {
    my ($body, $context) = @_;
    my @lines = split /\n/, $body // '';
    my $in = section_lines(\@lines);
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my @out;
    for my $i (sort { $a <=> $b } keys %$in) {
        next if $tag_re && $lines[$i] =~ $tag_re;
        my $e = parse_line($lines[$i]) // ($context && context_enabled() ? parse_context_line($lines[$i]) : undef) or next;
        $e->{line} = $lines[$i];
        push @out, $e;
    }
    return \@out;
}

# record_hashes(ctx, doc, \@ids [, {U-n => origin word}]) -> (n hashed, undef) | (0, why):
# publish, after the handoff is placed and read back. Exclusive create: an existing record is
# never rewritten (the same record again, from a retry, is fine). The record also keeps each
# hashed id's origin class word (`origins`, owner xxxxxxxx-12: no text), so a later carry of
# the handoff can count it in its approvals_carry row.
sub record_hashes {
    my ($ctx, $d, $ids, $origins) = @_;
    my %want = map { $_ => 1 } @{ $ids || [] };
    return (0, undef) unless %want;
    my $p = hash_path($ctx, $d->{fm}) or return (0, 'no-key');
    my %h;
    for my $e (@{ _section_entries($d->{body}) }) {
        next unless $want{ $e->{id} };
        return (0, 'duplicate') if exists $h{ $e->{id} };
        $h{ $e->{id} } = line_hash($e->{line});
    }
    return (0, 'no-line') unless %h;
    my %rec = (v => 1, session_id => $d->{fm}{session_id}, nonce => $d->{fm}{nonce}, lines => \%h);
    $rec{origins} = { map { $_ => _origin_word($origins->{$_}) } keys %h } if ref $origins eq 'HASH';
    my $json = skills::util::json_encode(\%rec) . "\n";
    my $ok = eval {
        skills::util::mkdir_p(File::Basename::dirname($p));
        skills::util::write_excl($p, $json, 0600);
    };
    return (0, 'write') unless defined $ok;
    return (scalar(keys %h), undef) if $ok;
    my $have = skills::util::read_file($p, 65536);
    return (defined $have && $have eq $json) ? (scalar(keys %h), undef) : (0, 'exists');
}

# The record of a handoff as stored, or undef when there is none or it does not fit the file.
sub _record_of {
    my ($ctx, $d) = @_;
    my $p = hash_path($ctx, $d->{fm}) or return undef;
    return undef unless -f $p && !-l $p;
    my $r = eval { skills::util::json_decode(skills::util::read_file($p, 65536)) };
    return undef unless ref $r eq 'HASH' && ($r->{v} // 0) eq '1' && ref $r->{lines} eq 'HASH'
        && ($r->{session_id} // '') eq ($d->{fm}{session_id} // '') && ($r->{nonce} // '') eq ($d->{fm}{nonce} // '');
    return $r;
}

# The origins a handoff's record keeps: {U-n => origin word} ({} for a record without them, or
# no record; owner xxxxxxxx-12).
sub origins_of {
    my ($ctx, $d) = @_;
    my $r = _record_of($ctx, $d) or return {};
    return {} unless ref $r->{origins} eq 'HASH';
    return { map { $_ => _origin_word($r->{origins}{$_}) } grep { /\AU-[0-9]+\z/ } keys %{ $r->{origins} } };
}

# The record of a handoff: {U-n => hex}, or undef when there is none or it does not fit the file.
sub hashes_of {
    my ($ctx, $d) = @_;
    my $r = _record_of($ctx, $d) or return undef;
    my %h;
    for my $id (keys %{ $r->{lines} }) {
        my $x = $r->{lines}{$id};
        $h{$id} = $x if $id =~ /\AU-[0-9]+\z/ && defined $x && !ref $x && $x =~ /\A[0-9a-f]{64}\z/;
    }
    return \%h;
}

# verify_checked(ctx, doc, {U-n => 1}) -> ({U-n => 1} verified, {U-n => unhashed|missing|changed})
# for the checked ids that have a line in `## Approvals`; an id on two lines is changed.
sub verify_checked {
    my ($ctx, $d, $ok) = @_;
    my (%good, %why, %lines);
    push @{ $lines{ $_->{id} } }, $_->{line} for @{ _section_entries($d->{body}) };
    my $rec = hashes_of($ctx, $d);
    for my $id (sort keys %{ $ok || {} }) {
        my $l = $lines{$id} or next;
        if (!$rec) { $why{$id} = 'unhashed' }
        elsif (!defined $rec->{$id}) { $why{$id} = 'missing' }
        elsif (@$l == 1 && line_hash($l->[0]) eq $rec->{$id}) { $good{$id} = 1 }
        else { $why{$id} = 'changed' }
    }
    return (\%good, \%why);
}

# transcript_path(ctx, sid, cwd…) -> this session's transcript, or undef: <config dir>/projects/
# <slug of a cwd>/<sid>.jsonl for the given folders, then the session's process records.
sub transcript_path {
    my ($ctx, $sid, @cwds) = @_;
    return undef unless skills::ctx::valid_sid($sid);
    my $cfg = skills::util::env('CLAUDE_CONFIG_DIR') // ((skills::util::env('HOME') // '') . '/.claude');
    my %seen;
    for my $c (grep { defined && $_ ne '' } map { ($_, skills::util::abs_path($_)) } grep { defined } @cwds) {
        next if $seen{$c}++;
        (my $slug = $c) =~ s/[^A-Za-z0-9]/-/g;
        my $p = "$cfg/projects/$slug/$sid.jsonl";
        return $p if -f $p;
    }
    if ($ctx) {
        require skills::jobs;
        return skills::jobs::transcript_of($ctx, $sid, undef);
    }
    return undef;
}

sub _entry {
    my ($e) = @_;
    my $t = "$e->{id} $e->{action} → " . join(', ', @{ $e->{targets} });
    $t = substr($t, 0, $ENTRY_MAX - 1) . '…' if length($t) > $ENTRY_MAX;
    return $t;
}

# The own relation of a handoff to this session for approval carry (spec §4 Approval (scoped);
# O-1; owner xxxxxxxx-27 revised): (1, '') when it is own, else (0, why). Own: a handoff in the
# private store (handoff_root; REVIEW-NIGHT-3 R3-03), not an export or an imported copy,
# integrity ok (a marker under the former name counts for an own-chain file, owner xxxxxxxx-26),
# written by this session or by a lineage predecessor reached through `clear` and
# `handoff-resume` links only (a link of any other kind cuts off every session before it too),
# and not cut by a successor's claim on a session of this line (_claim_cut: `claimed by a
# successor`, `written after the claim`).
sub own_relation {
    my ($d, $ctx, $sid) = @_;
    my $fm = $d->{fm} || {};
    return (0, 'export') if defined $fm->{export};
    return (0, 'imported') if defined $fm->{imported_from};
    return (0, 'not a handoff') unless ($fm->{kind} // '') eq 'handoff';
    return (0, 'outside the store') unless _in_store($d->{path}, $ctx);
    my $hs = $fm->{session_id} // '';
    my $chain = defined $sid ? skills::ctx::chain($ctx, $sid) : [];
    # Owner xxxxxxxx-26 (read-only alias): a file of this session or a lineage predecessor, in the
    # store, may carry its marker under the plugin's former name.
    my $own_chain = $hs ne '' && defined $sid && ($hs eq $sid || grep { $_->{sid} eq $hs } @$chain) ? 1 : 0;
    my $int = skills::store::integrity($d, alias => $own_chain)->{integrity} // '';
    return (0, $int eq '' ? 'integrity unknown' : $int) unless $int eq 'ok';
    return (0, 'foreign') unless defined $sid;
    my @line = ($sid);                         # this session, then each one up to the writer
    if ($hs eq '' || $hs ne $sid) {
        my ($cut, $found);
        for my $c (@$chain) {
            my $r = $c->{reason};
            my $word = defined $r && !ref $r && $r =~ /\A[a-z][a-z-]{0,23}\z/ ? $r : 'unknown link';
            $cut //= $word unless $CARRY_REASON{$word};
            push @line, $c->{sid};
            if ($c->{sid} eq $hs) { return (0, $cut) if defined $cut; $found = 1; last }
        }
        return (0, 'foreign') unless $found;
    }
    my $claimed = _claim_cut($ctx, $d, \@line);
    return (0, $claimed) if defined $claimed;
    return (1, '');
}

# claim_path(ctx, sid) -> `.sessions/successors/<sid>.json`, the claim that a session took sid's
# line over by resuming its newest handoff (skills::session_cmds::link_resume, exclusive create).
sub claim_path { my ($ctx, $s) = @_; return "$ctx->{root}/.sessions/$SUCCESSORS_DIR/$s.json" }

# successor_claim(ctx, sid) -> undef (no claim) | {session_id, epoch} | {bad => 1} (a claim file
# that does not read as one session id and a time).
sub successor_claim {
    my ($ctx, $s) = @_;
    return undef unless $ctx && defined $ctx->{root} && skills::ctx::valid_sid($s);
    my $p = claim_path($ctx, $s);
    return undef unless -e $p || -l $p;
    my $c = eval { skills::util::json_decode(skills::util::read_file($p, 65536)) };
    my ($cs, $ts) = ref $c eq 'HASH' ? ($c->{session_id}, $c->{ts}) : ();
    my $e = defined $ts && !ref $ts ? skills::util::iso_to_epoch($ts) : undef;
    return { bad => 1 } unless defined $cs && !ref $cs && skills::ctx::valid_sid($cs) && defined $e;
    return { session_id => $cs, epoch => $e };
}

# Root reading 2026-10-23 (fail closed; owner 2026-10-23 21:47 "1. OK"; review of the HR-1 build
# and of slice A): a claim by session S on the ended session P (claim_path) splits P's line at the
# claim's time, so a `once` approval is never used by both lines. Every session on the reader's
# line, from the reader up to the writer, is checked (\@line), so a handoff of P's own `/clear`
# predecessor is split the same way:
#   - on S's line (the reader reaches P through S) a handoff dated at or before the claim carries;
#     one dated after it belongs to P's continued line (`written after the claim`);
#   - on any other line through P (P resumed later, `claude --resume P`, or its `/clear`
#     successor) only a handoff dated after the claim carries (`claimed by a successor`).
# A file with no date counts as dated before the claim; an unreadable claim cuts. Returns the why,
# or undef.
sub _claim_cut {
    my ($ctx, $d, $line) = @_;
    for my $j (0 .. $#$line) {
        my $c = successor_claim($ctx, $line->[$j]) or next;
        return 'claimed by a successor' if $c->{bad};
        my $after = defined $d->{epoch} && $d->{epoch} > $c->{epoch} ? 1 : 0;
        if ($j > 0 && $line->[$j - 1] eq $c->{session_id}) { return 'written after the claim' if $after }
        elsif (!$after) { return 'claimed by a successor' }
    }
    return undef;
}

# quote_floor(ctx, sid) -> (1, undef) | (1, epoch) | (0): the time from which this session's
# typed rows and dialog answers count for a quote check. A session that another one claimed
# (claim_path) and that was resumed later counts only rows after the claim: its pre-claim
# approvals are context only (root reading 2026-10-23, owner 21:47 "1. OK"), as a fork's copied
# rows are. (0), the quote unchecked: no store, or a claim that does not read.
sub quote_floor {
    my ($ctx, $sid) = @_;
    return (0) unless $ctx && defined $ctx->{root};
    my $c = successor_claim($ctx, $sid) or return (1, undef);
    return (0) if $c->{bad};
    return (1, $c->{session_id} eq $sid ? undef : $c->{epoch});
}

# 1 when the file's real path lies under the store root (handoff_root), component by component.
sub _in_store {
    my ($path, $ctx) = @_;
    return 0 unless defined $path && $ctx && defined $ctx->{root};
    my $p = skills::util::abs_path($path);
    my $r = skills::util::abs_path($ctx->{root});
    return 0 unless defined $p && defined $r;
    $r =~ s{/+\z}{};
    return index($p, "$r/") == 0 ? 1 : 0;
}

# handoff_lines(doc, ctx, sid) -> (lines, row): `measure <handoff>` (AP-5).
sub handoff_lines {
    my ($d, $ctx, $sid) = @_;
    return ([], undef) unless enabled();
    my @lines = split /\n/, $d->{body} // '';
    my $in = section_lines(\@lines);
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my @own_idx = grep { !($tag_re && $lines[$_] =~ $tag_re) } sort { $a <=> $b } keys %$in;
    my @e = grep { defined } map { parse_line($lines[$_]) } @own_idx;
    # Context-only own lines (a plugin handoff turn, 0.1.2 D-8): never checked, listed as such.
    # A file publish wrote in a plugin handoff turn (frontmatter `requested_by: plugin`, AC-4)
    # names that reason, and none of its lines carries, whatever its approvals_checked says.
    my %cx;
    if (context_enabled()) {
        my $plugin = ($d->{fm}{requested_by} // '') eq 'plugin';
        my $label = $plugin ? 'plugin handoff' : 'written as context';
        for my $c (grep { defined } map { parse_context_line($lines[$_]) } @own_idx) { $cx{ $c->{id} } //= $label }
        if ($plugin) { $cx{ $_->{id} } //= $label for @e }
    }
    my ($own, $why) = own_relation($d, $ctx, $sid);
    if (!$own) {
        return ([ 'Approvals (checked): none (' . $why . ': context only)' ], { source => 'handoff', checked => 0, gate => 0, classes => [] }) if @e || %cx;
        return ([ 'Approvals (checked): none' ], { source => 'handoff', checked => 0, gate => 0, classes => [] });
    }
    # U3-01: a checked id carries only when its line matches the hash publish recorded.
    my ($ok, $unver) = verify_checked($ctx, $d, checked_ids($d->{fm}{approvals_checked}));
    # An id on two lines is no one's check (R3-05; publish refuses it, an edited file may not).
    my %n;
    $n{ $_->{id} }++ for @e;
    my $org = origins_of($ctx, $d);
    $_->{origin} = $org->{ $_->{id} } for @e;
    # An id that also has a context-only line is no one's check either.
    my ($out, $row) = _report([ grep { $ok->{ $_->{id} } && $n{ $_->{id} } == 1 && !$cx{ $_->{id} } } @e ], [], 'handoff');
    my %ctx_only = (%cx, map { $_ => $HASH_WHY{ $unver->{$_} } } keys %$unver);
    my @bad = sort { (substr($a, 2) <=> substr($b, 2)) } keys %ctx_only;
    if (@bad) {
        push @$out, 'Approvals (context only, re-ask): ' . join(', ', map { "$_ ($ctx_only{$_})" } @bad);
        $row->{unverified} = scalar keys %$unver if %$unver;
        $row->{context} = scalar keys %cx if %cx;
    }
    return ($out, $row);
}

# summary_lines(copy text, transcript path [, cwd, sid]) -> (lines, row): `measure --compact --copy` (AP-5).
sub summary_lines {
    my ($text, $transcript, $cwd, $sid) = @_;
    return ([], undef) unless enabled();
    my $tag_re = skills::spec::regex_at('carry.tag_re');
    my (@e, %seen);
    for my $l (split /\n/, $text // '') {
        next if $tag_re && $l =~ $tag_re;
        while ($l =~ /$LOOSE_RE/g) {
            my %x = (n => $1, quote => $2, action => $3, targets_text => $4, scope => $5, state => $6);
            $x{id} = "U-$x{n}";
            next if $seen{ $x{id} }++;
            push @e, _finish(\%x);
        }
    }
    return ([ 'Approvals (checked): none' ], { source => 'summary', checked => 0, gate => 0, classes => [] }) unless @e;
    # A session another one claimed counts only rows after the claim (quote_floor). The store root
    # is the run context's (rc, set up by the measure command); no context: unchecked.
    my $root = defined &rc::root ? eval { rc::root() } : undef;
    my $ctx = defined $root && !ref $root && $root ne '' ? { root => $root } : undef;
    my ($fok, $floor) = quote_floor($ctx, $sid);
    my @org;
    my $res = defined $transcript && $fok
        ? skills::core::quotes_found($transcript, [ map { _ask($_) } @e ], $sid, after => $floor, origins => \@org)
        : undef;
    my (@ok, @no);
    for my $k (0 .. $#e) {
        if ($res && $res->[$k]) { $e[$k]{origin} = $org[$k]; push @ok, $e[$k] } else { push @no, $e[$k] }
    }
    return _report(\@ok, \@no, 'summary', $cwd);
}

sub _report {
    my ($ok, $no, $source, $cwd) = @_;
    my (@carry, @gate, %cls);
    for my $e (@$ok) {
        my $c = classes($e, $cwd);
        if (defined $c->{gate}) { push @gate, $e; next }
        next if $e->{used} && !$e->{standing};
        push @carry, $e;
        $cls{$_} = 1 for @{ $c->{outward} };
    }
    my @out = ('Approvals (checked): ' . (@carry ? join('; ', map { _entry($_) } @carry) : 'none'));
    push @out, 'Approvals (gate, re-ask): ' . join('; ', map { _entry($_) } @gate) if @gate;
    push @out, 'Approvals (unchecked): ' . join(', ', map { $_->{id} } @$no) if @$no;
    # Owner xxxxxxxx-12 "Count, log origin": the carried approvals by the origin of the row their
    # quote was found in (class words only, never text).
    return (\@out, { source => $source, checked => scalar(@carry), gate => scalar(@gate), unchecked => scalar(@$no),
                     classes => [ sort keys %cls ], (@carry ? (origins => _origin_counts(\@carry)) : ()) });
}

1;

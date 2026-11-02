package transcript;
# lib/transcript.pm: read-only transcript facts, parsed by key (TF Q3 §1a). Owner: WP-core.
# Only ids, counts, flags and timestamps leave this module; text is read in memory.
use strict;
use warnings;
use utf8;

# boundary(line) -> {uuid, ts, epoch, trigger, pre, post, duration_ms, precomputed, version} or undef
sub boundary {
    my ($line) = @_;
    return undef unless index($line, 'compact_boundary') >= 0;
    my $j = eval { jsonc::decode($line) };
    return undef unless ref $j eq 'HASH' && ($j->{subtype} // '') eq 'compact_boundary';
    my $m = ref $j->{compactMetadata} eq 'HASH' ? $j->{compactMetadata} : {};
    return { uuid => $j->{uuid}, ts => $j->{timestamp}, epoch => util::parse_iso($j->{timestamp} // '') // 0,
             trigger => $m->{trigger}, pre => $m->{preTokens}, post => $m->{postTokens},
             duration_ms => $m->{durationMs}, precomputed => ($m->{precomputed} ? 1 : 0),
             version => ((defined $j->{version} && !ref $j->{version}) ? $j->{version} : undef) };
}

# The native idle-compaction notices (IC-1 D1): a system row whose content starts with one of
# these prefixes, after a main boundary row, marks that compaction as idle. The prefixes come
# from canary-baseline.json c8.idle_prefixes (tools/canary-baseline, C8 counts them in the
# binary); the literals are the fallback for a baseline without them. Only the prefix is
# matched; no text leaves this module.
our %IDLE_FALLBACK = (notice => 'Compacted while idle', return => 'Compacted using a summary written while you were away');
our $IDLE_PREFIXES;
sub idle_prefixes {
    return $IDLE_PREFIXES if $IDLE_PREFIXES;
    my %p = %IDLE_FALLBACK;
    my $raw = util::read_file(ctx::asset_path('canary-baseline.json'));
    my $b = defined $raw ? eval { jsonc::decode($raw) } : undef;
    my $ip = ref $b eq 'HASH' && ref $b->{c8} eq 'HASH' ? $b->{c8}{idle_prefixes} : undef;
    if (ref $ip eq 'HASH') {
        for my $k (keys %IDLE_FALLBACK) { $p{$k} = $ip->{$k} if defined $ip->{$k} && !ref $ip->{$k} && $ip->{$k} ne '' }
    }
    return $IDLE_PREFIXES = \%p;
}

# idle_notice(line) -> 'notice' | 'return' for a system row whose content starts with a native
# idle prefix, else undef
sub idle_notice {
    my ($line) = @_;
    return undef unless index($line, '"system"') >= 0;
    my $p = idle_prefixes();
    my @hit = grep { index($line, $p->{$_}) >= 0 } sort keys %$p;
    return undef unless @hit;
    my $j = eval { jsonc::decode($line) };
    return undef unless ref $j eq 'HASH' && ($j->{type} // '') eq 'system' && defined $j->{content} && !ref $j->{content};
    for my $k (@hit) { return $k if index($j->{content}, $p->{$k}) == 0 }
    return undef;
}

# The engine's closing sentences of a transcript summary row (not in a PostCompact
# compact_summary, so not in a copy): cut from the row's end before its body sha is taken
# (fix-escalations 1, option (b): this reader's own cut; the shared copy_trailers lists stay).
our @ENGINE_TRAILERS = (
    qr/^If you need specific details from before compaction \(/,
    qr/^Continue the conversation from where it left off without asking/,
    qr/^The messages after this summary are the most recent messages from before compaction/,
);

# summary_facts(line) -> {n => marker nonce | undef, h => normalized-body sha256} for an
# isCompactSummary user row, else undef. In memory only: no text leaves (C-STORE D5 step 1).
sub summary_facts {
    my ($line) = @_;
    return undef unless index($line, 'isCompactSummary') >= 0;
    my $j = eval { jsonc::decode($line) };
    return undef unless ref $j eq 'HASH' && ($j->{type} // '') eq 'user' && $j->{isCompactSummary};
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    my $text = !ref $c ? $c : ref $c eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c) : undef;
    return undef unless defined $text;
    my @l = split /\n/, $text, -1;
    while (@l && ($l[-1] =~ /^\s*$/ || grep { $l[-1] =~ $_ } @ENGINE_TRAILERS)) { pop @l }
    my $s = detect::scan(join("\n", @l));
    return { n => $s->{nonce}, h => sha::hex256($s->{normalized}) };
}

# version(path) -> the Claude Code version of the newest row that has one in the last 64 KB
# (PKG-RUNTIME D.2 source 3), or undef
sub version {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $tail = util::read_tail($path, 64 * 1024) // return undef;
    for my $line (reverse split /\n/, $tail) {
        next unless index($line, '"version"') >= 0;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && defined $j->{version} && !ref $j->{version};
        return $j->{version} if $j->{version} =~ /^\d+\.\d+\.\d+([.+-][0-9A-Za-z.+-]*)?$/;
    }
    return undef;
}

# boundaries(path [, tail => bytes]) -> [{uuid, ts, epoch, trigger, pre, post, duration_ms, precomputed}]
# (tail: only the last bytes of the file, for a hook that wants the newest rows)
sub boundaries {
    my ($path, %o) = @_;
    my @out;
    return \@out unless defined $path && -f $path;
    if ($o{tail}) {
        my $data = util::read_tail($path, $o{tail}) // return \@out;
        for my $line (split /\n/, $data) { my $b = boundary($line); push @out, $b if $b }
        return \@out;
    }
    open(my $fh, '<:raw', $path) or return \@out;
    while (my $line = <$fh>) { my $b = boundary($line); push @out, $b if $b }
    close $fh;
    return \@out;
}

sub count { return scalar @{ boundaries($_[0]) } }

# last_prompt_epoch(path) -> epoch of the last user-typed row (not a tool result,
# not a compact summary, not meta) in the last 2 MB, or undef
sub last_prompt_epoch {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $tail = util::read_tail($path, 2 * 1024 * 1024) // return undef;
    my $best;
    for my $line (split /\n/, $tail) {
        next unless index($line, '"user"') >= 0;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'user';
        next if $j->{isCompactSummary} || $j->{isMeta} || $j->{isSidechain};
        my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
        next if ref $c eq 'ARRAY' && grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c;
        my $e = util::parse_iso($j->{timestamp} // '');
        $best = $e if defined $e && (!defined $best || $e > $best);
    }
    return $best;
}

# AP-4 (spec §15 approval-quote, SPEC-DELTAS §3.1 (c)). quotes_found(path, [{quote, targets =>
# [identity…], action}…], sid, since => epoch [, origins => \@kinds]) -> [1|0…] in the order
# given, or undef when the transcript cannot be read (no file, unreadable) or the session's id
# or start is unknown (see "Own rows only" below). One pass, in memory; no text is stored,
# logged or returned. With `origins`, $kinds[i] is set for each quote found to the class word of
# the row that held it (the row's origin kind of @HUMAN_ORIGINS, `none` for a typed row without
# one, `dialog` for a dialog answer); owner xxxxxxxx-12 "Count, log origin": the approvals_carry
# row counts them, never any text. A quote counts when it occurs, white space folded, in a
# human-typed user row: type user, not isMeta / isCompactSummary / isSidechain, no tool result,
# origin kind absent or a person's (@HUMAN_ORIGINS), and not a notification, command-output or
# reminder text. A quote of $SHORT_WORDS words or more counts as whole words in the message
# (REVIEW-NIGHT-3 R3-04: "push to main" is not in "push to maintenance"). A shorter quote must
# be the whole message (case, end dots and exclamation marks aside: "yes", "Yes!"; never a "yes"
# inside "yes, but not now" or an "ok" inside "token"), and the assistant text since the
# previous human row must name one of its targets (the identity before ` @ `, or that
# identity's last word): it directly answers that message.
#
# Matching item (owner xxxxxxxx-06 "Matching item", NIGHT-REVIEW 2.7, R3-04): a short quote may
# also be one whole numbered line of a message (the owner answers in numbered lists: "1. publish
# yourself." as line 1 of a 3-line reply), with the same "assistant text names a target" rule.
# The whole-message rule above applies only when neither the message nor the quote starts with
# an item number; a numbered reply, one line or several, goes through these rules. An unnumbered
# line of a longer message never counts. The veto and the permit are kept apart. The line's item
# number (`1.`, `1)`, `1:`, after an optional list bullet or bold mark) n decides first:
# (a) when any numbered item of the assistant text (any list, one followed by prose, a later
#     row or a code block included) names one of the targets, only this rule may permit: the line
#     counts only when the closing list (the numbered list that ends the text) has exactly one
#     item naming a target and n is that item's number;
# (b) only when no numbered item of the assistant text names a target (or it has no list), the
#     line counts when it holds an outward verb of the action (@ITEM_VERBS: push, merge, publish,
#     deploy …; never an object noun or a descriptive word such as "comments" or "retry") or a
#     target id.
# So no line counts when two or more items of the closing list name a target, nor when the list
# that names it is followed by any further line (asked again). A line holding a refusal word
# ($ITEM_NO: "no", "not", "don't", "wait", "later", "tomorrow" …) or ending in a question mark
# never counts, and a refusal on an unnumbered line of the reply makes no line count. "1. yes /
# 2. no" to "1. Run the tests? 2. Push feat/x?" never confirms the push with "1. yes", nor does
# "1. yes, push" to "1. Push feat/x? 2. Push feat/y?" confirm feat/y, with or without a line after
# the list. A quote written with its item number ("1. publish yourself.") must match that number.
# An unindented line that is no item, or a fence line, ends a list; a number not above the one
# before it starts a new list; a numbered line indented more than the list's first item is part
# of the current item (a sub-list). A list inside a code block is never the closing list.
#
# Owner-ruled quote sources (owner xxxxxxxx-09 "Quote src", 2026-10-26: all four kept as built,
# no longer provisional): Q-1 code checks each quote against the user's own rows at all (O-3);
# Q-2 a message that holds an approval line (`U-n: approval`) or a moved approval's re-ask item
# was pasted, so none of its words count ($PASTED); Q-3 rows stamped with another session's id do not count ("Own rows only"
# below); Q-4 quotes match whole words only. SDK-origin rows (`claude -p`, Agent SDK hosts) count
# as the user's words (owner xxxxxxxx-12 "Count, log origin"; their count is logged, see above).
# Only the last $QUOTE_SCAN_MAX bytes are read; a quote not found in a longer file is undef for
# that quote (not checked, never a miss).
#
# Dialog answers (NR-14, owner xxxxxxxx-23 "Dialogs count", xxxxxxxx-20): the user's answer in
# an AskUserQuestion dialog counts as their words. The result row must answer a tool_use named
# exactly $ASK_TOOL in a main (not isSidechain) assistant row, by its tool_use_id, and pass the
# same row rules as a typed message (not isSidechain / isMeta / isCompactSummary, no other
# session's id); it must hold that one tool result, not an error, with the structured record
# Claude Code writes beside it (toolUseResult: answers, annotations, response). Only the answer
# counts: a chosen option label (each label of a multiSelect answer too), the typed Other text,
# a note the user wrote on a question, and a free-text response; each must also appear in the
# result text the model saw (`"<question>"="<answer>"`, ` notes: <note>`). The question text,
# headers, option descriptions and previews are never a quote source. A short quote must be a
# whole answer, and that answer's question text (all of the dialog's questions for a response)
# must name a target, as for a typed short quote. Not counted: a dismissed or empty dialog
# ("The user did not answer the questions"), a selection left when the dialog timed out
# (afkTimeoutMs), a round where the user asked for more questions (followUp), a result row
# without the structured record, a result row whose permissionDecision names a source other than
# the user (user_temporary, user_permanent: a hook, a rule or a classifier answered), a dialog
# whose tool_use input already held answers (answers, annotations, response, followUp,
# afkTimeoutMs: the model's pre-fill), a result whose sourceToolAssistantUUID is not the asking
# row's uuid, a dialog whose tool_use_id another tool's call reuses before the result, and any
# other tool's output or any tool_use input.
#
# Own rows only (owner 2026-10-23 xxxxxxxx-27 revised, "No: forks re-ask"; REVIEW-NIGHT-3
# R3-03): every row a quote, a short quote's assistant context, a dialog's ask or its result is
# read from must have been written by this session after it started: no other session's id, no
# forkedFrom, and a timestamp at or after `since` (sessions::own_since: the session's first
# per-process record). Claude Code 2.1.309 writes the history it copies into a new session with
# the new session's id and the parent's uuids and times: `/branch` adds forkedFrom, while a
# `--fork-session` resume and a background copy (sessionKind bg) add no marker, so their copied
# rows are told apart by time only. A row without a readable timestamp never counts. With no
# `since` or no sid nothing can be shown to be own, so the result is undef (not checked, never a
# miss). Target ids are matched as whole tokens: `MR !1` is not in `MR !12`.
#
# Coarse start (sessions::own_start, `coarse => 1`; review of bcdaca6): a record without
# milliseconds names only the second the session started in. Rows at or after `until` are own
# by time. A row stamped in [since, until) is own only when it is a typed user row (the launch
# prompt; never a dialog answer or an assistant row) that comes, in file order, after a main
# SessionStart hook row (an `attachment` row with hookEvent SessionStart) stamped in or after
# `since`, with no row stamped before `since` between the two. Copied history is written before
# the new session's hook rows and keeps the parent's older times, so a copy never passes; a
# session whose hook rows are missing, or a file read only in part, misses the launch prompt
# (not checked), never counts a copy.
our @HUMAN_ORIGINS = qw(human composer bridge sdk);
our $SHORT_WORDS = 4;
our $QUOTE_SCAN_MAX = 256 * 1024 * 1024;
our $ASSISTANT_KEEP = 64 * 1024;
our $ASK_TOOL = 'AskUserQuestion';
our $ASK_KEEP = 256;                  # dialogs awaiting their answer, at most
my $NOTES_ONLY = '(notes only)';      # the answer value of a question with a note and no option
my $NOT_TYPED = qr/\A\s*<(?:task-notification|local-command-stdout|local-command-stderr|bash-stdout|bash-stderr|system-reminder|local-command-caveat)\b/;
# Q-2 also covers the re-ask item publish writes for a moved approval (0.1.3 APPROVALS,
# skills::approvals::move_lines: `words recorded as the user's:` before the words, `as written:`
# for a line that did not parse, `(was U-<k>; not carried:` after them): those words failed the
# quote check, so a message pasting them must not make them count.
my $PASTED = qr/\bU-[0-9]+:[ \t]*approval\b|\bwords recorded as the user['\x{2019}]s:|\bre-ask before acting:[ \t]*as written:|\(was U-[0-9]+; not carried:/;
# Matching item: an item line of a numbered list (an optional `-`/`*`/`+` bullet and a bold
# mark around the number), its number and its text.
my $ITEM_RE = qr/\A[ \t]*(?:[-*+][ \t]+)?(?:\*\*|__)?([0-9]{1,3})[.):](?:\*\*|__)?(?:[ \t]+(.*))?\z/s;
# A fence line of a code block.
my $FENCE_RE = qr/\A[ \t]*(?:```|~~~)/;
# The outward verbs a reply line may name under rule (b): [verb, its forms]. Only these make a
# line "hold the action"; an object noun or a descriptive word of the model-written action
# ("comments", "retry", "commit", "update") never does.
our @ITEM_VERBS = (
    [ 'force-push', qr/force[- ]?push(?:es|ed|ing)?/ ],
    [ 'push',       qr/push(?:es|ed|ing)?/ ],
    [ 'merge',      qr/merg(?:e|es|ed|ing)/ ],
    [ 'publish',    qr/publish(?:es|ed|ing)?/ ],
    [ 'deploy',     qr/deploy(?:s|ed|ing)?/ ],
    [ 'rebase',     qr/rebas(?:e|es|ed|ing)/ ],
    [ 'squash',     qr/squash(?:es|ed|ing)?/ ],
    [ 'amend',      qr/amend(?:s|ed|ing)?/ ],
    [ 'delete',     qr/delet(?:e|es|ed|ing)/ ],
    [ 'wipe',       qr/wip(?:e|es|ed|ing)/ ],
);
# A refusal or a delay in a reply line: such a line is never an approval, and such an unnumbered
# line in a numbered reply makes no line of it count.
my $ITEM_NO = qr/(?<![A-Za-z'\x{2019}])(?:no|not|nope|nah|never|don['\x{2019}]?t|wait|later|stop|cancel|hold|skip|tomorrow|pause|abort|postpone)(?![A-Za-z'\x{2019}])|n['\x{2019}]t(?![A-Za-z])/i;

# A short quote and a message compared whole: folded, lower case, end dots and `!` dropped.
sub _whole { my ($s) = @_; my $x = lc _fold($s); $x =~ s/[.!\s]+\z//; return $x }

# The outward verbs (@ITEM_VERBS) a text names: {verb => 1}.
sub _verbs {
    my ($s) = @_;
    my $t = lc _chars($s // '');
    my %v;
    for my $x (@ITEM_VERBS) {
        my $re = $x->[1];
        $v{ $x->[0] } = 1 if $t =~ /(?<![a-z0-9_])$re(?![a-z0-9_-])/;
    }
    # "force-push" is a push too, and "push" inside "force-push" is that verb alone.
    $v{push} = 1 if $v{'force-push'};
    return \%v;
}

# The numbered lists of an assistant text: {lists => [{items => {number => item text}}...],
# closing => the list that ends the text or undef}. An unindented line that is no item, or a
# fence line, ends a list; a number not above the one before it starts a new list; a numbered
# line indented more than the list's first item, and an indented line, belong to the current
# item. Lists inside a code block are lists too (for the veto), but never the closing list, and a
# code block left open at the end leaves no closing list.
sub _lists {
    my ($text) = @_;
    my (@lists, $L, $cur, $prev, $ind, $fence);
    for my $l (split /\n/, $text // '') {
        if ($l =~ $FENCE_RE) { $fence = !$fence; ($L, $cur, $prev, $ind) = (); next }
        next if $l !~ /\S/;
        my ($li) = $l =~ /\A([ \t]*)/;
        my $w = length($li =~ s/\t/    /gr);
        if ($l =~ $ITEM_RE && !(defined $cur && $w > $ind)) {
            my $n = 0 + $1;
            if (!$L || $n <= $prev) { $L = { items => {}, fenced => ($fence ? 1 : 0) }; push @lists, $L; $ind = $w }
            ($cur, $prev) = ($n, $n);
            $L->{items}{$n} = $l;
        } elsif (defined $cur && $w > 0) {
            $L->{items}{$cur} .= "\n$l";
        } else {
            ($L, $cur, $prev, $ind) = ();
        }
    }
    my $closing = $L && !$fence && !$L->{fenced} ? $L : undef;
    return { lists => \@lists, closing => $closing };
}

# _matching_item(message, quote record, assistant text) -> 1 when one whole numbered line of the
# message is the short quote and either (a) a numbered item of the assistant text names a target,
# the closing list has exactly one such item and the line's number is that item's, or (b) no
# numbered item of the assistant text names a target and the line holds an outward verb of the
# action or a target id (owner xxxxxxxx-06; see "Matching item" above). The caller has checked
# that the assistant text names a target.
sub _matching_item {
    my ($msg, $q, $asst) = @_;
    my @lines = split /\n/, $msg;
    # A refusal on an unnumbered line of a numbered reply ("wait, don't push yet") retracts it.
    return 0 if grep { $_ !~ $ITEM_RE && _fold($_) =~ $ITEM_NO } @lines;
    my $ctx;
    for my $l (@lines) {
        next unless $l =~ $ITEM_RE;
        my ($n, $body) = (0 + $1, $2 // '');
        next unless _whole($body) eq $q->{wbody};
        next if defined $q->{qnum} && $n != $q->{qnum};
        my $fl = _fold($body);
        next if $fl =~ $ITEM_NO;
        # A question back ("1. push it?"), or a pasted copy of the assistant's own questions.
        next if $fl =~ /[?\x{ff1f}]\s*\z/;
        $ctx //= do {
            my $ls = _lists($asst);
            my $names = sub { my ($it) = @_; scalar grep { $it =~ $_ } @{ $q->{ids} } };
            my $any = grep { $names->($_) } map { values %{ $_->{items} } } @{ $ls->{lists} };
            my @named = $ls->{closing}
                ? grep { $names->($ls->{closing}{items}{$_}) } sort { $a <=> $b } keys %{ $ls->{closing}{items} }
                : ();
            { veto => $any ? 1 : 0, named => \@named };
        };
        if ($ctx->{veto}) {
            # Only (a) may permit: the one item of the closing list that names the target.
            return 1 if @{ $ctx->{named} } == 1 && $ctx->{named}[0] == $n;
            next;
        }
        return 1 if grep { $fl =~ $_ } @{ $q->{ids} };
        my $lv = _verbs($fl);
        return 1 if grep { $lv->{$_} } keys %{ $q->{averbs} };
    }
    return 0;
}

sub _chars {
    my ($s) = @_;
    return '' unless defined $s;
    return $s if utf8::is_utf8($s) || $s !~ /[^\x00-\x7f]/;
    my $c = $s;
    return utf8::decode($c) ? $c : $s;
}

sub _fold { my ($s) = @_; $s = _chars($s); $s =~ s/\s+/ /g; $s =~ s/\A | \z//g; return $s }

# The text blocks of a row's message content (a string, or text items of an array).
sub _row_text {
    my ($j) = @_;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    return $c if defined $c && !ref $c;
    return '' unless ref $c eq 'ARRAY';
    return join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c);
}

# A row this session wrote after it started (see "Own rows only" above): no forkedFrom, no other
# session's id, a timestamp at or after $since. Fail closed: no sid, no since or no readable
# timestamp is 0.
sub _own_row {
    my ($j, $sid, $since) = @_;
    return 0 unless ref $j eq 'HASH' && defined $sid && defined $since;
    return 0 if exists $j->{forkedFrom};
    return 0 if exists $j->{sessionId} && (ref $j->{sessionId} || ($j->{sessionId} // '') ne $sid);
    my $ts = $j->{timestamp};
    return 0 unless defined $ts && !ref $ts;
    my $e = util::parse_iso($ts);
    return defined $e && $e >= $since ? 1 : 0;
}

# A row's own timestamp as an epoch, or undef.
sub _row_epoch {
    my ($j) = @_;
    return undef unless ref $j eq 'HASH';
    my $ts = $j->{timestamp};
    return undef unless defined $ts && !ref $ts;
    return util::parse_iso($ts);
}

# A main SessionStart hook row (the coarse-start anchor).
sub _session_start_row {
    my ($j) = @_;
    return 0 unless ref $j eq 'HASH' && ($j->{type} // '') eq 'attachment' && !$j->{isSidechain};
    my $a = $j->{attachment};
    return (ref $a eq 'HASH' && ($a->{hookEvent} // '') eq 'SessionStart') ? 1 : 0;
}

# A user row that may hold this session's own input: type user, not isMeta / isCompactSummary /
# isSidechain / isVisibleInTranscriptOnly, and one of this session's own rows (_own_row).
sub _own_user_row {
    my ($j, $sid, $since) = @_;
    return 0 unless ref $j eq 'HASH' && ($j->{type} // '') eq 'user';
    return 0 if $j->{isMeta} || $j->{isCompactSummary} || $j->{isSidechain} || $j->{isVisibleInTranscriptOnly};
    return _own_row($j, $sid, $since);
}

# Keys of an AskUserQuestion input that only Claude Code's permission component may fill: a
# tool_use that already holds one was pre-filled by the model, so its dialog never counts.
my @ASK_FILLED = qw(answers annotations response followUp afkTimeoutMs);

# Record the AskUserQuestion dialogs of a main assistant row: {tool_use_id => {uuid, qs =>
# [{key, text, multi, labels}]}} (uuid: the asking row's; key: the question as the answers
# record names it; text: in characters).
sub _dialogs_asked {
    my ($j, $asked, $order) = @_;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    return unless ref $c eq 'ARRAY';
    for my $it (@$c) {
        next unless ref $it eq 'HASH' && ($it->{type} // '') eq 'tool_use' && ($it->{name} // '') eq $ASK_TOOL;
        my $id = $it->{id};
        next unless defined $id && !ref $id && $id ne '';
        if (ref $it->{input} eq 'HASH' && grep { exists $it->{input}{$_} } @ASK_FILLED) { delete $asked->{$id}; next }
        my $in = ref $it->{input} eq 'HASH' ? $it->{input}{questions} : undef;
        next unless ref $in eq 'ARRAY';
        my @qs;
        for my $q (@$in) {
            next unless ref $q eq 'HASH' && defined $q->{question} && !ref $q->{question} && $q->{question} ne '';
            my %labels = map { (_chars($_->{label}) => 1) }
                grep { ref $_ eq 'HASH' && defined $_->{label} && !ref $_->{label} } @{ ref $q->{options} eq 'ARRAY' ? $q->{options} : [] };
            push @qs, { key => $q->{question}, text => _chars($q->{question}), multi => ($q->{multiSelect} ? 1 : 0), labels => \%labels };
        }
        next unless @qs;
        push @$order, $id unless $asked->{$id};
        $asked->{$id} = { uuid => (defined $j->{uuid} && !ref $j->{uuid} ? $j->{uuid} : undef), qs => \@qs };
    }
    while (@$order > $ASK_KEEP) { delete $asked->{ shift @$order } }
}

# Forget a pending dialog whose tool_use_id another tool's call reuses (any assistant row): its
# result could no longer be told apart.
sub _drop_reused {
    my ($j, $asked) = @_;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    return unless ref $c eq 'ARRAY';
    for my $it (@$c) {
        next unless ref $it eq 'HASH' && ($it->{type} // '') eq 'tool_use' && ($it->{name} // '') ne $ASK_TOOL;
        my $id = $it->{id};
        delete $asked->{$id} if defined $id && !ref $id;
    }
}

# The labels of a multiSelect answer as Claude Code joins them (", " between labels; a label
# holding ", " or a double quote is written as a JSON string), or () unless every part is one of
# the question's option labels.
sub _picked_labels {
    my ($s, $labels) = @_;
    my (@out, $rest);
    $rest = $s;
    while (1) {
        my $item;
        if ($rest =~ s/\A("(?:[^"\\]|\\.)*")//s) {
            $item = eval { jsonc::decode($1) };
            return () unless defined $item && !ref $item;
            $item = _chars($item);
        } else {
            $rest =~ s/\A(.*?)(?=, |\z)//s;
            $item = $1;
        }
        push @out, $item;
        last if $rest eq '';
        return () unless $rest =~ s/\A, //;
    }
    return () if grep { !$labels->{$_} } @out;
    return @out;
}

# The user's own answers in a dialog result row: [{text, ctx}] (ctx: the question text a short
# answer must name a target in), or () when the row answers no recorded dialog or does not count.
# The dialog is forgotten once its result is seen.
sub _dialog_answers {
    my ($j, $asked) = @_;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    return () unless ref $c eq 'ARRAY';
    my @tr = grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c;
    my @mine = grep { defined $_->{tool_use_id} && !ref $_->{tool_use_id} && $asked->{ $_->{tool_use_id} } } @tr;
    return () unless @mine;
    my @ds = map { delete $asked->{ $_->{tool_use_id} } } @mine;
    my @qs = map { @{ $_->{qs} } } @ds;
    # The structured record belongs to the row, so it names one result only.
    return () unless @tr == 1;
    my $r = $tr[0];
    return () if $r->{is_error};
    # The result names the row that asked (sourceToolAssistantUUID), when both carry a uuid.
    my $src = $j->{sourceToolAssistantUUID};
    return () if defined $src && (ref $src || (defined $ds[0]{uuid} && $src ne $ds[0]{uuid}));
    # Who answered: when Claude Code records it, only the user (not a hook, rule or classifier).
    if (exists $j->{permissionDecision}) {
        my $pd = $j->{permissionDecision};
        return () unless ref $pd eq 'HASH' && defined $pd->{source} && !ref $pd->{source}
            && ($pd->{source} eq 'user_temporary' || $pd->{source} eq 'user_permanent');
        return () if defined $pd->{decision} && $pd->{decision} ne 'accept';
    }
    my $u = $j->{toolUseResult};
    return () unless ref $u eq 'HASH' && ref $u->{answers} eq 'HASH';
    return () if $u->{afkTimeoutMs} || $u->{followUp};
    my $rc = $r->{content};
    my $shown = !ref $rc ? ($rc // '')
        : ref $rc eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$rc) : '';
    $shown = _chars($shown);
    my $ann = ref $u->{annotations} eq 'HASH' ? $u->{annotations} : {};
    my @out;
    for my $q (@qs) {
        my $v = $u->{answers}{ $q->{key} };
        my $head = qq{"$q->{text}"=};
        if (ref $v eq 'ARRAY') {
            my @vals = map { _chars($_) } grep { defined $_ && !ref $_ && $_ ne '' } @$v;
            if (@vals && @vals == @$v && index($shown, $head . '"') >= 0 && !grep { index($shown, $_) < 0 } @vals) {
                push @out, map { { text => $_, ctx => $q->{text} } } @vals;
                push @out, { text => join(', ', @vals), ctx => $q->{text} } if @vals > 1;
            }
        } elsif (defined $v && !ref $v && $v ne '' && $v ne $NOTES_ONLY) {
            my $s = _chars($v);
            if (index($shown, $head . qq{"$s"}) >= 0) {
                push @out, { text => $s, ctx => $q->{text} };
                if ($q->{multi}) {
                    my @l = _picked_labels($s, $q->{labels});
                    push @out, map { { text => $_, ctx => $q->{text} } } @l if @l > 1;
                }
            }
        }
        my $an = $ann->{ $q->{key} };
        my $n = ref $an eq 'HASH' && defined $an->{notes} && !ref $an->{notes} ? _chars($an->{notes}) : '';
        push @out, { text => $n, ctx => $q->{text} } if $n =~ /\S/ && index($shown, " notes: $n") >= 0;
    }
    my $resp = defined $u->{response} && !ref $u->{response} ? _chars($u->{response}) : '';
    push @out, { text => $resp, ctx => join("\n", map { $_->{text} } @qs) } if $resp =~ /\S/ && index($shown, $resp) >= 0;
    # A dialog answer that holds an approval line was pasted: none of its answers count.
    return () if grep { $_->{text} =~ $PASTED } @out;
    return @out;
}

sub quotes_found {
    my ($path, $asks, $sid, %o) = @_;
    my $since = $o{since};
    return undef unless defined $path && -f $path && -r _;
    # Fail closed: without this session's id and start no row can be shown to be its own.
    return undef unless defined $sid && !ref $sid && $sid ne '' && defined $since && !ref $since && $since =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    # Coarse start: rows at or after `until` are own by time, rows in [since, until) by order only.
    my $coarse = $o{coarse} ? 1 : 0;
    my $until = $since;
    if ($coarse) {
        $until = $o{until};
        return undef unless defined $until && !ref $until && $until =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $until > $since;
    }
    my @q = map { { quote => _fold($_->{quote}), short => 0, ids => [] } } @$asks;
    for my $i (0 .. $#q) {
        my @w = split / /, $q[$i]{quote};
        $q[$i]{short} = @w < $SHORT_WORDS ? 1 : 0;
        my @ids;
        for my $t (@{ $asks->[$i]{targets} || [] }) {
            my $id = _chars($t);
            $id =~ s/\s+@\s.*\z//s;
            $id =~ s/\A\s+|\s+\z//g;
            next if $id eq '';
            push @ids, $id;
            my ($last) = $id =~ /(\S+)\z/;
            push @ids, $last if defined $last && $last ne $id && length($last) >= 2;
        }
        # Whole tokens: `MR !1` must not match inside `MR !12`, nor `feat/x` inside `feat/xy`,
        # `feat/x-old`, `feat/x.old`, `feat/x/old` or `old-feat/x`.
        $q[$i]{ids} = [ map { my $p = /\A\w/ ? '(?<![\w-])' : ''; my $s = /\w\z/ ? '(?![\w-]|[.\/][\w-])' : ''; qr/$p\Q$_\E$s/ } @ids ];
        my $qq = $q[$i]{quote};
        my $pre = $qq =~ /\A\w/ ? '(?<!\w)' : '';
        my $post = $qq =~ /\w\z/ ? '(?!\w)' : '';
        $q[$i]{re} = qr/$pre\Q$qq\E$post/;
        $q[$i]{whole} = _whole($qq);
        # Matching item: the quote without its own item number, and that number.
        my ($qn, $qb) = $qq =~ $ITEM_RE ? (0 + $1, $2 // '') : (undef, $qq);
        $q[$i]{qnum} = $qn;
        $q[$i]{wbody} = _whole($qb);
        $q[$i]{averbs} = _verbs($asks->[$i]{action});
    }
    my $origins = ref $o{origins} eq 'ARRAY' ? $o{origins} : undef;
    my @found = map { $_->{quote} eq '' ? 0 : undef } @q;
    my $need_asst = grep { $_->{short} } @q;
    my $size = -s $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $partial = defined $size && $size > $QUOTE_SCAN_MAX;
    if ($partial) { seek($fh, $size - $QUOTE_SCAN_MAX, 0); my $skip = <$fh> }
    my %human = map { $_ => 1 } @HUMAN_ORIGINS;
    my $asst = '';
    my (%asked, @asked_order);
    # The coarse-start window: open until the first row stamped at or after `until` (copied rows
    # are all older); $anchored while a SessionStart hook row stamped in or after `since` was seen
    # and no older row came after it. Never opened on a file read only in part.
    my ($window, $anchored) = ($coarse && !$partial ? 1 : 0, 0);
    while (my $line = <$fh>) {
        my $j;
        my $early = 0;
        if ($window) {
            $j = eval { jsonc::decode($line) };
            my $e = _row_epoch($j);
            if (defined $e) {
                if ($e >= $until) { $window = 0 }
                elsif ($e < $since) { $anchored = 0 }
                elsif (_session_start_row($j)) { $anchored = 1 }
                else { $early = $anchored }
            }
        }
        if (index($line, '"assistant"') >= 0
            && ($need_asst || index($line, $ASK_TOOL) >= 0
                || (%asked && index($line, '"tool_use"') >= 0 && grep { index($line, $_) >= 0 } keys %asked))) {
            $j = eval { jsonc::decode($line) };
            if (ref $j eq 'HASH' && ($j->{type} // '') eq 'assistant') {
                _drop_reused($j, \%asked) if %asked;
                # Only this session's own assistant rows name a short quote's target or ask a
                # dialog: a copied question is the parent's (owner xxxxxxxx-27 revised).
                if (!$j->{isSidechain} && _own_row($j, $sid, $until)) {
                    if ($need_asst) {
                        $asst .= "\n" . _chars(_row_text($j));
                        $asst = substr($asst, -$ASSISTANT_KEEP) if length($asst) > $ASSISTANT_KEEP;
                    }
                    _dialogs_asked($j, \%asked, \@asked_order);
                }
                next;
            }
        }
        next unless index($line, '"user"') >= 0;
        if (index($line, '"tool_use_id"') >= 0) {
            # A tool result: only the user's answer in an AskUserQuestion dialog counts (NR-14).
            next unless %asked;
            $j //= eval { jsonc::decode($line) };
            next unless _own_user_row($j, $sid, $until);
            my $ok = ref $j->{origin} eq 'HASH' ? $j->{origin}{kind} : undef;
            next if defined $ok && !$human{$ok};
            my @ans = _dialog_answers($j, \%asked);
            for my $d (@ans) {
                my $ft = _fold($d->{text});
                my $fw = _whole($d->{text});
                for my $i (0 .. $#q) {
                    next if $found[$i] || $q[$i]{quote} eq '';
                    if ($q[$i]{short}) {
                        next unless $fw eq $q[$i]{whole};
                        next unless grep { $d->{ctx} =~ $_ } @{ $q[$i]{ids} };
                    } else {
                        next unless $ft =~ $q[$i]{re};
                    }
                    $found[$i] = 1;
                    $origins->[$i] = 'dialog' if $origins;
                }
            }
            next;
        }
        $j //= eval { jsonc::decode($line) };
        # A typed row in the coarse window counts only by order (see "Coarse start" above).
        next unless _own_user_row($j, $sid, $until) || ($early && _own_user_row($j, $sid, $since));
        my $o = ref $j->{origin} eq 'HASH' ? $j->{origin}{kind} : undef;
        next if defined $o && !$human{$o};
        my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
        next if ref $c eq 'ARRAY' && grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c;
        my $t = _chars(_row_text($j));
        if ($t =~ $NOT_TYPED) { next }
        if ($t =~ $PASTED) { $asst = ''; next }
        my $ft = _fold($t);
        my $fw = _whole($t);
        for my $i (0 .. $#q) {
            next if $found[$i] || $q[$i]{quote} eq '';
            if ($q[$i]{short}) {
                next unless grep { $asst =~ $_ } @{ $q[$i]{ids} };
                # The whole message when neither it nor the quote is numbered, else one whole
                # numbered line of it that answers the matching item (owner xxxxxxxx-06).
                if ($ft !~ $ITEM_RE && !defined $q[$i]{qnum}) { next unless $fw eq $q[$i]{whole} }
                else { next unless $q[$i]{wbody} ne '' && _matching_item($t, $q[$i], $asst) }
            } else {
                next unless $ft =~ $q[$i]{re};
            }
            $found[$i] = 1;
            $origins->[$i] = (defined $o ? $o : 'none') if $origins;
        }
        $asst = '';
    }
    close $fh;
    return [ map { $found[$_] ? 1 : $partial ? undef : 0 } 0 .. $#q ];
}

# user_quote_found(path, quote, [target…], sid, since) -> 1 | 0 | undef (unreadable, no sid or
# start, or not found in the scanned tail of a longer file): the one-quote form of quotes_found.
sub user_quote_found {
    my ($path, $quote, $targets, $sid, $since) = @_;
    my $r = quotes_found($path, [{ quote => $quote, targets => $targets }], $sid, since => $since) or return undef;
    return $r->[0];
}

# Denied calls (0.1.2 AC-2, mitigation 1 of the classifier incident): a tool call of this
# session, its subagents and workflow agents included, whose result Claude Code wrote as a
# permission denial. `classifier`: the auto-mode classifier refused it; `rule`: a deny rule, a
# denied directory, a built-in safety check or the permission mode did; `user`: the user rejected
# it at the prompt. A refusal by a hook is none of these and does not count.
# The structured decision Claude Code writes on the tool result's row (`permissionDecision`:
# {decision accept|reject, source, reasonType}) is read when present; the text patterns below are
# the fallback for versions without it. A rule's text quotes the command, which may span lines (a
# heredoc commit message chained with a push; review finding 3).
our @DENIED = (
    [ classifier => qr/\A\s*Permission for this action (?:was|has been) denied by (?:the )?(?:Claude Code )?auto[- ]mode classifier/ ],
    [ rule       => qr/\A\s*Permission to use \S+ (?:[\s\S]*? )?has been denied/ ],
    [ rule       => qr/\A\s*(?:<tool_use_error>\s*)?File is in a directory that is denied by your permission settings/ ],
    [ rule       => qr/\A\s*Permission for this command was denied by a built-in Claude Code safety check/ ],
    [ rule       => qr/\A\s*Claude requested permissions to write to [\s\S]+?, but you haven't granted it yet/ ],
    # Review 3 finding 4: refusal texts of Claude Code versions without permissionDecision.
    [ rule       => qr/\A\s*Claude requested permissions to edit [\s\S]+? which is a sensitive file/ ],
    [ rule       => qr/\A\s*This command requires approval/ ],
    [ rule       => qr/\A\s*This (?:Bash )?command contains multiple operations\. The following parts? requires? approval/ ],
    [ rule       => qr/\A\s*A [A-Za-z ]{1,40} in this command can't be checked before it runs/ ],
    [ rule       => qr/\A\s*\S+ (?:from|to) '[^\n]*?' was blocked by a deny rule/ ],
    [ user       => qr/\A\s*The user doesn't want to proceed with this tool use/ ],
    [ user       => qr/\A\s*Permission for this tool use[ ]was denied\. The tool use[ ]was rejected/ ],
);
# Words one of the texts above holds: a result row with none of them is not decoded.
our @DENIED_HINTS = ('denied', 'want to proceed', "haven't granted", '"reject"', 'sensitive file',
    'requires approval', "require\x20approval", "can't be checked", 'deny rule');
# Tools whose input holds file text: only their path is kept.
my %DENIED_PATH_ONLY = map { $_ => 1 } qw(Write Edit MultiEdit NotebookEdit);
our $DENIED_VALUE_MAX = 200;      # longer input values (a body, a description) are skipped
our $DENIED_TEXT_MAX = 2000;
our $DENIED_AGENT_FILES_MAX = 2000;

# _denied_class(row, tool_result text, results on the row) -> class | undef. The row's
# structured decision wins when present (one result on the row): `reject` by the user at the
# prompt is `user`, by the classifier `classifier`, by a hook nothing, else `rule`; `accept` is
# no denial whatever the text says. Without it, the text patterns decide.
sub _denied_class {
    my ($j, $t, $n) = @_;
    my $pd = $j->{permissionDecision};
    if ($n == 1 && ref $pd eq 'HASH' && defined $pd->{decision} && !ref $pd->{decision}) {
        return undef unless $pd->{decision} eq 'reject';
        my ($src, $why) = map { defined $_ && !ref $_ ? $_ : '' } $pd->{source}, $pd->{reasonType};
        return undef if $src eq 'hook' || $why eq 'hook';
        return 'user' if $src =~ /\Auser/;
        return 'classifier' if $why eq 'classifier';
        return 'rule';
    }
    return undef unless defined $t && !ref $t;
    for my $d (@DENIED) { return $d->[0] if $t =~ $d->[1] }
    return undef;
}

# denied_calls(path, sid) -> [{tool, class, epoch, text}] | undef (main transcript unreadable):
# the denied calls of the main transcript (sidechain rows included) and of the session's subagent
# and workflow agent transcripts (`<transcript or sid>/subagents/agent-*.jsonl`,
# `…/subagents/workflows/<run>/agent-*.jsonl`), oldest first, any session's rows of a file
# included (a copied denial counts: fail closed). `text` is the call's input words in memory only,
# for the approvals lint to tell which approval a denial covers; it is never logged or printed:
# the Bash command, the path of a Write, Edit, MultiEdit or NotebookEdit, else the input's scalar
# values up to $DENIED_VALUE_MAX characters each.
sub denied_calls {
    my ($path, $sid) = @_;
    return undef unless defined $path && -f $path && -r _;
    my $main = _denied_in_file($path);
    return undef unless $main;
    my @out = @$main;
    push @out, @{ _denied_in_file($_) || [] } for _denied_agent_files($path, $sid);
    my $i = 0;
    return [ map { $_->[1] } sort { ($a->[1]{epoch} // 0) <=> ($b->[1]{epoch} // 0) || $a->[0] <=> $b->[0] } map { [ $i++, $_ ] } @out ];
}

# The session's subagent and workflow agent transcripts (at most $DENIED_AGENT_FILES_MAX).
sub _denied_agent_files {
    my ($path, $sid) = @_;
    my $dir = util::dirname($path);
    (my $stem = util::basename($path)) =~ s/\.jsonl\z//;
    my @out;
    for my $base (grep { defined && $_ ne '' } $stem, $sid) {
        my $d = "$dir/$base/subagents";
        next unless -d $d;
        push @out, map { "$d/$_" } grep { /\Aagent-[A-Za-z0-9_-]+\.jsonl\z/ } util::list_dir($d);
        my $w = "$d/workflows";
        for my $run (grep { /\A[A-Za-z0-9_.-]+\z/ && !/\A\.\.?\z/ && -d "$w/$_" } util::list_dir($w)) {
            push @out, map { "$w/$run/$_" } grep { /\Aagent-[A-Za-z0-9_-]+\.jsonl\z/ } util::list_dir("$w/$run");
        }
        last if @out;
    }
    splice(@out, $DENIED_AGENT_FILES_MAX) if @out > $DENIED_AGENT_FILES_MAX;
    return @out;
}

# One transcript's denied calls. Two passes: the results are found by plain index first, so a
# transcript with no denial is read once without decoding.
sub _denied_in_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my %res;
    while (my $line = <$fh>) {
        next unless index($line, '"tool_use_id"') >= 0 && grep { index($line, $_) >= 0 } @DENIED_HINTS;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'user';
        my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
        next unless ref $c eq 'ARRAY';
        my @tr = grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c;
        for my $it (@tr) {
            my $id = $it->{tool_use_id};
            next unless defined $id && !ref $id && $id ne '';
            my $t = $it->{content};
            $t = join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$t) if ref $t eq 'ARRAY';
            my $class = _denied_class($j, $t, scalar @tr);
            $res{$id} = { class => $class, epoch => _row_epoch($j) } if defined $class;
        }
    }
    unless (%res) { close $fh; return [] }
    seek($fh, 0, 0);
    my @out;
    while (my $line = <$fh>) {
        next unless index($line, '"tool_use"') >= 0 && grep { index($line, $_) >= 0 } keys %res;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'assistant';
        my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
        next unless ref $c eq 'ARRAY';
        for my $it (@$c) {
            next unless ref $it eq 'HASH' && ($it->{type} // '') eq 'tool_use';
            my $id = $it->{id};
            next unless defined $id && !ref $id && $res{$id};
            my $tool = $it->{name};
            next unless defined $tool && !ref $tool && $tool ne '';
            my $r = delete $res{$id};
            push @out, { tool => $tool, class => $r->{class}, epoch => $r->{epoch} // _row_epoch($j),
                         text => _denied_text($tool, $it->{input}) };
        }
    }
    close $fh;
    return \@out;
}

sub _denied_text {
    my ($tool, $in) = @_;
    my $t;
    if (ref $in ne 'HASH') { $t = defined $in && !ref $in ? $in : '' }
    elsif ($tool eq 'Bash') { $t = defined $in->{command} && !ref $in->{command} ? $in->{command} : '' }
    elsif ($DENIED_PATH_ONLY{$tool}) {
        $t = join(' ', grep { defined && !ref } $in->{file_path}, $in->{notebook_path});
    } else {
        my @v;
        my $walk;
        $walk = sub {
            my ($x, $depth) = @_;
            return if $depth > 3;
            if (ref $x eq 'HASH') { $walk->($x->{$_}, $depth + 1) for sort keys %$x }
            elsif (ref $x eq 'ARRAY') { $walk->($_, $depth + 1) for @$x }
            elsif (defined $x && !ref $x && length($x) <= $DENIED_VALUE_MAX) { push @v, $x }
        };
        $walk->($in, 0);
        undef $walk;
        $t = join(' ', @v);
    }
    $t = substr($t, 0, $DENIED_TEXT_MAX) if length($t) > $DENIED_TEXT_MAX;
    return $t;
}

# subagent_files(main transcript path, sid) -> [{path, agent_id}]
sub subagent_files {
    my ($path, $sid) = @_;
    return [] unless defined $path && $path ne '';
    my $dir = util::dirname($path);
    my $stem = util::basename($path);
    $stem =~ s/\.jsonl$//;
    my @out;
    for my $base (grep { defined } ($stem, $sid)) {
        my $d = "$dir/$base/subagents";
        next unless -d $d;
        for my $f (util::list_dir($d)) {
            next unless $f =~ /^agent-([A-Za-z0-9_-]+)\.jsonl$/;
            push @out, { path => "$d/$f", agent_id => $1 };
        }
        last if @out;
    }
    return \@out;
}

# Temp paths cited in the last 5 MB of a transcript (sweep scope, OD-9).
sub temp_paths {
    my ($path, $tmpdir) = @_;
    return [] unless defined $path && -f $path;
    my $tail = util::read_tail($path, 5 * 1024 * 1024) // return [];
    my @roots = ('/tmp/', '/private/tmp/', '/var/folders/');
    push @roots, "$tmpdir/" if defined $tmpdir && $tmpdir =~ m{^/} && $tmpdir ne '/';
    my %seen;
    my @out;
    while ($tail =~ m{((?:/private)?/(?:tmp|var/folders)/[^\s"'<>\\|;&\x60]+|[^\s"'<>\\|;&\x60]*/tasks/[A-Za-z0-9_.-]+\.output)}g) {
        my $p = $1;
        $p =~ s/[),.:]+$//;
        next if $seen{$p}++;
        push @out, $p;
    }
    if (defined $tmpdir && $tmpdir =~ m{^/.+}) {
        my $t = $tmpdir;
        $t =~ s{/+$}{};
        while ($tail =~ m{(\Q$t\E/[^\s"'<>\\|;&\x60]+)}g) {
            my $p = $1;
            $p =~ s/[),.:]+$//;
            next if $seen{$p}++;
            push @out, $p;
        }
    }
    return \@out;
}

1;

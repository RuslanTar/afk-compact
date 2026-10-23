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

# AP-4 (spec §15 approval-quote, SPEC-DELTAS §3.1 (c); provisional on owner decision O-3: code
# checks the quote). quotes_found(path, [{quote, targets => [identity…]}…], sid, since => epoch)
# -> [1|0…] in the order given, or undef when the transcript cannot be read (no file, unreadable)
# or the session's id or start is unknown (see "Own rows only" below). One pass, in
# memory; no text is stored, logged or returned. A quote counts when it occurs, white space
# folded, in a human-typed user row: type user, not isMeta / isCompactSummary / isSidechain, no
# tool result, origin kind absent or a person's (@HUMAN_ORIGINS), and not a notification,
# command-output or reminder text. A quote of $SHORT_WORDS words or more counts as whole words
# in the message (REVIEW-NIGHT-3 R3-04: "push to main" is not in "push to maintenance"). A
# shorter quote must be the whole message (case, end dots and exclamation marks aside: "yes",
# "Yes!"; never a "yes" inside "yes, but not now" or an "ok" inside "token"), and the assistant
# text since the previous human row must name one of its targets (the identity before ` @ `, or
# that identity's last word): it directly answers that message. A message that holds an
# approval line (`U-n: approval`) was pasted, so none of its words count. Only the last
# $QUOTE_SCAN_MAX bytes are read; a quote not found in a longer file is undef for that quote
# (not checked, never a miss).
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
our @HUMAN_ORIGINS = qw(human composer bridge sdk);
our $SHORT_WORDS = 4;
our $QUOTE_SCAN_MAX = 256 * 1024 * 1024;
our $ASSISTANT_KEEP = 64 * 1024;
our $ASK_TOOL = 'AskUserQuestion';
our $ASK_KEEP = 256;                  # dialogs awaiting their answer, at most
my $NOTES_ONLY = '(notes only)';      # the answer value of a question with a note and no option
my $NOT_TYPED = qr/\A\s*<(?:task-notification|local-command-stdout|local-command-stderr|bash-stdout|bash-stderr|system-reminder|local-command-caveat)\b/;
my $PASTED = qr/\bU-[0-9]+:[ \t]*approval\b/;

# A short quote and a message compared whole: folded, lower case, end dots and `!` dropped.
sub _whole { my ($s) = @_; my $x = lc _fold($s); $x =~ s/[.!\s]+\z//; return $x }

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
        # Whole tokens: `MR !1` must not match inside `MR !12`, nor `feat/x` inside `feat/xy`.
        $q[$i]{ids} = [ map { my $p = /\A\w/ ? '(?<!\w)' : ''; my $s = /\w\z/ ? '(?!\w)' : ''; qr/$p\Q$_\E$s/ } @ids ];
        my $qq = $q[$i]{quote};
        my $pre = $qq =~ /\A\w/ ? '(?<!\w)' : '';
        my $post = $qq =~ /\w\z/ ? '(?!\w)' : '';
        $q[$i]{re} = qr/$pre\Q$qq\E$post/;
        $q[$i]{whole} = _whole($qq);
    }
    my @found = map { $_->{quote} eq '' ? 0 : undef } @q;
    my $need_asst = grep { $_->{short} } @q;
    my $size = -s $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $partial = defined $size && $size > $QUOTE_SCAN_MAX;
    if ($partial) { seek($fh, $size - $QUOTE_SCAN_MAX, 0); my $skip = <$fh> }
    my %human = map { $_ => 1 } @HUMAN_ORIGINS;
    my $asst = '';
    my (%asked, @asked_order);
    while (my $line = <$fh>) {
        my $j;
        if (index($line, '"assistant"') >= 0
            && ($need_asst || index($line, $ASK_TOOL) >= 0
                || (%asked && index($line, '"tool_use"') >= 0 && grep { index($line, $_) >= 0 } keys %asked))) {
            $j = eval { jsonc::decode($line) };
            if (ref $j eq 'HASH' && ($j->{type} // '') eq 'assistant') {
                _drop_reused($j, \%asked) if %asked;
                # Only this session's own assistant rows name a short quote's target or ask a
                # dialog: a copied question is the parent's (owner xxxxxxxx-27 revised).
                if (!$j->{isSidechain} && _own_row($j, $sid, $since)) {
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
            next unless _own_user_row($j, $sid, $since);
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
                }
            }
            next;
        }
        $j //= eval { jsonc::decode($line) };
        next unless _own_user_row($j, $sid, $since);
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
                next unless $fw eq $q[$i]{whole};
                next unless grep { $asst =~ $_ } @{ $q[$i]{ids} };
            } else {
                next unless $ft =~ $q[$i]{re};
            }
            $found[$i] = 1;
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

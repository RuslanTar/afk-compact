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
# checks the quote). quotes_found(path, [{quote, targets => [identity…]}…]) -> [1|0…] in the
# order given, or undef when the transcript cannot be read (no file, unreadable). One pass, in
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
our @HUMAN_ORIGINS = qw(human composer bridge sdk);
our $SHORT_WORDS = 4;
our $QUOTE_SCAN_MAX = 256 * 1024 * 1024;
our $ASSISTANT_KEEP = 64 * 1024;
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

sub quotes_found {
    my ($path, $asks, $sid) = @_;
    return undef unless defined $path && -f $path && -r _;
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
        $q[$i]{ids} = \@ids;
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
    while (my $line = <$fh>) {
        if ($need_asst && index($line, '"assistant"') >= 0) {
            my $j = eval { jsonc::decode($line) };
            if (ref $j eq 'HASH' && ($j->{type} // '') eq 'assistant' && !$j->{isSidechain}) {
                $asst .= "\n" . _chars(_row_text($j));
                $asst = substr($asst, -$ASSISTANT_KEEP) if length($asst) > $ASSISTANT_KEEP;
            }
            next;
        }
        next unless index($line, '"user"') >= 0;
        next if index($line, '"tool_use_id"') >= 0;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'user';
        next if $j->{isMeta} || $j->{isCompactSummary} || $j->{isSidechain} || $j->{isVisibleInTranscriptOnly};
        # A row stamped with another session's id (a fork's or a resume's copied history) is
        # not this session's message (REVIEW-NIGHT-3 R3-03; O-12 interim: a fork carries none).
        next if defined $sid && defined $j->{sessionId} && !ref $j->{sessionId} && $j->{sessionId} ne $sid;
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
                next unless grep { index($asst, $_) >= 0 } @{ $q[$i]{ids} };
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

# user_quote_found(path, quote, [target…]) -> 1 | 0 | undef (unreadable, or not found in the
# scanned tail of a longer file): the one-quote form of quotes_found.
sub user_quote_found {
    my ($path, $quote, $targets) = @_;
    my $r = quotes_found($path, [{ quote => $quote, targets => $targets }]) or return undef;
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

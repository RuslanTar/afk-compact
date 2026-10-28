package copies;
# lib/copies.pm: summary copies (MOD-SPEC §5.3 step 3, §7; OD-11, OD-12). Owner: WP-core.
#   main    -> <bucket>/compact/<stamp>_<sid8>_c<seq>-<id6>.md
#   sub     -> <bucket>/compact/subagents/<stamp>_<sid8>[-a<agent8>]_c<seq>-<id6>.md
#   unknown -> <bucket>/compact/unattributed/<stamp>_<sid8>_<id6>.md
# <id6> = nonce6, or h + 5 hex of the normalized body's sha256. One copy per id6:
# an existing file is verified by sha (EXISTS sha-match / sha-differs), never
# replaced; a true h-id collision with other content gets -2. seq under seq.lock.
# Mode 0400; frontmatter from the dispatch record and the boundary row only.
use strict;
use warnings;
use utf8;

our @SLOTS = ('compact', 'compact/subagents', 'compact/unattributed');

sub slot_dir {
    my ($bucket, $scope) = @_;
    return "$bucket/compact" if $scope eq 'main';
    return "$bucket/compact/subagents" if $scope eq 'sub';
    return "$bucket/compact/unattributed";
}

sub id6 {
    my ($nonce, $sha) = @_;
    return substr($nonce, 0, 6) if nonce::valid($nonce);
    return 'h' . substr($sha, 0, 5);
}

# find(bucket, id6) -> path of the copy carrying this id6, or undef
sub find {
    my ($bucket, $id6) = @_;
    for my $s (@SLOTS) {
        for my $f (util::list_dir("$bucket/$s")) {
            return "$bucket/$s/$f" if $f =~ /[-_]\Q$id6\E\.md$/;
        }
    }
    return undef;
}

# body sha of an existing copy (the original's sha when the copy is redacted)
sub copy_sha {
    my ($path) = @_;
    my $raw = util::read_file($path) // return (undef, {});
    my ($fm, $body) = frontmatter::read($raw);
    return (undef, {}) unless $fm;
    if (defined $fm->{redacted} && $fm->{redacted} =~ /sha256 ([0-9a-f]{64})/) { return ($1, $fm) }
    # The copy holds the normalized body (final \n); an empty body is written as one \n.
    $body = '' if $body eq "\n";
    return (sha::hex256($body), $fm);
}

# Is this path one of the plugin's own raw-summary stashes of this session
# (<watch>/<sid>/pending/<id6>.post.md or <nonce>.mod.md)?
sub own_stash {
    my ($path) = @_;
    my $sd = rc::sid_dir();
    return 0 unless defined $path && defined $sd && -f $path && !-l $path;
    return 0 unless util::basename($path) =~ /\A(?:[0-9a-f]{6}|h[0-9a-f]{5}(?:-\d+)?)\.post\.md\z|\A[0-9a-f]{8}\.mod\.md\z/;
    my $real = util::real_path($path);
    my $dir = util::real_path("$sd/pending");
    return (defined $real && defined $dir && util::dirname($real) eq $dir) ? 1 : 0;
}

# drop_stash(path, result) -> 1 when removed. ROOT-RULINGS F2-7 (PRIV-03): once a copy holds
# the summary (saved, unattributed, late, or EXISTS sha-match), the plugin's own transient
# raw stash goes, so a HARD secret redacted in the copy does not stay beside it. Only our
# stash files; an unsaved stash (refused, mismatch, deferred) stays for reconcile. The
# content-free .post.json meta stays.
sub drop_stash {
    my ($path, $result) = @_;
    return 0 unless defined $result && $result =~ /\A(?:saved|unattributed|late|exists)\z/;
    return 0 unless own_stash($path);
    return unlink($path) ? 1 : 0;
}

# settle_mismatch(path => stash, save => copies::save result (EXISTS sha-differs), scan => scan)
# -> 'dropped' | 'kept' | undef (not our stash, or no mismatch). RRP-04, MOD-SPEC §5.8 cases 2-3:
#   redundant: the stash verdict is ok-trailer and its body cut after the sentinel line has the
#     copy's body sha (an engine trailer only in this text, AT-M3-17) -> the stash goes,
#     row stash_dropped {id6, nonce, why: redundant, copy_rel};
#   real: the stash is rewritten with the summary-copy redaction (HARD, as a saved copy) to
#     pending/<id>.<post|mod>.mismatch.md (0600, temp + link, never over an earlier keep), its
#     sha side file beside it, then the raw stash goes; row stash_kept {id6, nonce, why: mismatch,
#     redacted_n}. Kept files are never deleted by the plugin (D-8).
sub settle_mismatch {
    my (%a) = @_;
    my ($path, $save) = @a{qw(path save)};
    return undef unless ref $save eq 'HASH' && ($save->{result} // '') eq 'mismatch';
    return undef unless own_stash($path);
    my $text = util::read_file($path) // return undef;
    my $s = $a{scan} || detect::scan($text);
    my $raw_sha = sha::hex256($s->{normalized});
    my ($csha) = defined $save->{path} ? copy_sha($save->{path}) : (undef);
    my $base = util::basename($path);
    my ($stem, $kind) = $base =~ /\A(.+)\.(post|mod)\.md\z/ or return undef;
    my $id6 = $save->{id6} // ($kind eq 'mod' ? substr($stem, 0, 6) : $stem);
    my $nonce = $save->{nonce} // ($kind eq 'mod' ? $stem : undef);
    if (($save->{verdict} // '') eq 'ok-trailer' && defined $csha && defined $s->{sentinel_from_end}) {
        my @b = @{ $s->{lines} };
        my ($k, $at) = (0, undef);
        for (my $j = $#b; $j >= 0; $j--) {
            next if $b[$j] =~ /^\s*$/;
            if (++$k == $s->{sentinel_from_end}) { $at = $j; last }
        }
        if (defined $at && sha::hex256(join("\n", @b[0 .. $at]) . "\n") eq $csha) {
            return undef unless unlink $path;
            rc::emit('stash_dropped', [id6 => $id6, nonce => $nonce, why => 'redundant', copy_rel => $save->{rel}]);
            return 'dropped';
        }
    }
    my $chars = $text;
    utf8::decode($chars) unless utf8::is_utf8($chars);
    my ($kept, $rh) = secrets::redact($chars, ['HARD']);
    my $n = 0;
    $n += $_->{count} for @$rh;
    my $dir = util::dirname($path);
    my $target;
    my $tmp = sprintf('%s/.%s.%s.mismatch.tmp-%d-%04x', $dir, $stem, $kind, $$, int(rand(65536)));
    return undef unless eval { util::write_excl($tmp, $kept, 0600) };
    for my $try (1 .. 9) {
        my $cand = "$dir/$stem.$kind" . ($try > 1 ? "-$try" : '') . '.mismatch.md';
        if (link($tmp, $cand)) { $target = $cand; last }
        last unless $!{EEXIST};
    }
    unlink $tmp;
    return undef unless defined $target;
    (my $side = $target) =~ s/\.md\z/.json/;
    my $kb = $kept;
    utf8::encode($kb) if utf8::is_utf8($kb);
    eval {
        util::write_excl($side, jsonc::encode_bytes(jsonc::obj(
            v => 1, id6 => $id6, nonce => $nonce, kind => $kind, raw_sha256 => $raw_sha, kept_sha256 => sha::hex256($kb),
            redacted => sprintf('%d (%s)', $n, ($n ? secrets::rule_ids($rh) : '-')), copy_rel => $save->{rel},
            copy_sha256 => $csha, ts => util::iso_ms(util::now()))) . "\n", 0600);
    };
    unlink $path;
    rc::emit('stash_kept', [id6 => $id6, nonce => $nonce, why => 'mismatch', redacted_n => $n]);
    return 'kept';
}

# attribute(path => old copy, agent => agent id, proof => a|b|c) -> {ok => 1, path, rel, seq}
# or {why}: MOD-SPEC §5.9 step 3 (fill). A sub-unknown copy in compact/subagents/ is
# re-created under <same stamp>_<sid8>-a<agent8>_c<seq'>-<id6>.md (seq' under seq.lock), its
# frontmatter the old one in the old order with actor, compaction_seq replaced and
# attributed_by, attributed_at, renamed_from added; the body byte-identical. Exclusive create,
# 0400, then re-read: the frontmatter parses and the body sha equals the old body's; only then
# the old name is unlinked (OD-17: a new file, never an edit in place). Any failure leaves the
# old file, and a new file that was written but did not verify is unlinked.
sub attribute {
    my (%a) = @_;
    my ($old, $agent, $proof) = @a{qw(path agent proof)};
    my $base = util::basename($old // '');
    return { why => 'not-sub-unknown' } unless $base =~ /\A(\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d)_([0-9a-z]{8})_c\d+-([0-9a-z-]+)\.md\z/;
    my ($stamp, $sid8, $id6) = ($1, $2, $3);
    my $dir = util::dirname($old);
    return { why => 'not-subagents' } unless util::basename($dir) eq 'subagents' && util::basename(util::dirname($dir)) eq 'compact';
    return { why => 'agent' } unless defined $agent && $agent =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/;
    my $raw = util::read_file($old) // return { why => 'unreadable' };
    return { why => 'frontmatter' } unless $raw =~ /\A(---\n)(.*?\n)(---\n)(.*)\z/s;
    my ($head, $body) = ($2, $4);
    my ($fm) = frontmatter::read($raw);
    return { why => 'frontmatter' } unless $fm && ($fm->{actor} // '') eq 'sub-unknown';
    my $sid = $fm->{session_id} // return { why => 'frontmatter' };
    my $body_sha = sha::hex256($body);
    my $tag = '-a' . substr($agent, 0, 8);
    my $sd = rc::sid_dir() // return { why => 'no-watch' };
    my $out = eval {
        lock::with("$sd/seq.lock", { sid => $sid, actor => $agent }, sub {
            my $seq = _seq($dir, $sid8, $tag);
            my $new = "$dir/${stamp}_${sid8}${tag}_c${seq}-$id6.md";
            my @lines;
            for my $l (split /\n/, $head) {
                if ($l =~ /\Aactor: /) { push @lines, 'actor: ' . frontmatter::_scalar($agent) }
                elsif ($l =~ /\Acompaction_seq: /) { push @lines, "compaction_seq: $seq" }
                else { push @lines, $l }
            }
            push @lines, "compaction_seq: $seq" unless grep { /\Acompaction_seq: / } @lines;
            push @lines, 'attributed_by: ' . frontmatter::_scalar("reconcile-$proof"), 'attributed_at: ' . frontmatter::_scalar(util::iso(util::now())),
                         'renamed_from: ' . frontmatter::_scalar($base);
            my $data = "---\n" . join("\n", @lines) . "\n---\n" . $body;
            return { why => 'exists' } unless util::write_excl($new, $data, 0400);
            _test_corrupt($new);
            my $back = util::read_file($new);
            my ($bfm) = frontmatter::read($back);
            my ($bbody) = defined $back && $back =~ /\A---\n.*?\n---\n(.*)\z/s;
            if (!$bfm || ($bfm->{actor} // '') ne $agent || !defined $bbody || sha::hex256($bbody) ne $body_sha) {
                unlink $new;
                return { why => 'verify' };
            }
            unlink($old) or do { unlink $new; return { why => 'unlink' } };
            return { ok => 1, path => $new, seq => $seq };
        }, wait_ms => 500);
    };
    return { why => (($@ // '') =~ /lock-timeout/ ? 'lock-timeout' : 'write-error') } unless $out;
    $out->{rel} = substr($out->{path}, length(rc::root()) + 1) if $out->{ok};
    return $out;
}

# Test seam (STORE_TEST_MODE only): STORE_TEST_FILL_CORRUPT=1 flips one byte of a fill's new
# file before its read-back, so the verification fails (AT-ST-09 c).
sub _test_corrupt {
    my ($p) = @_;
    return unless util::test_mode() && ($ENV{STORE_TEST_FILL_CORRUPT} // '') eq '1';
    chmod 0600, $p;
    my $d = util::read_file($p) // return;
    substr($d, -2, 1) = substr($d, -2, 1) eq 'x' ? 'y' : 'x';
    open(my $fh, '>:raw', $p) or return;
    print $fh $d;
    close $fh;
    chmod 0400, $p;
}

# Away digest phase 1 (owner 2026-10-27 12:5x; AWAY-DIGEST build item 6): the copy's frontmatter
# status from the summary's own Status word: finished (or the older done) is completed, a blocked
# lane (hard-blocked, soft-blocked, or the older blocked and waiting-*) is blocked, anything else
# (working, active, none) is in-progress. The model's word, not a checked fact, read as the
# plugin's lane check reads the summary's own text (hooks/lib/lane.ts laneFacts and laneOf, less
# what only the session measures): the Status, Step 1 and Gate lines from `## Resume here` (the
# whole body when it has none), the steps from `## Next steps` alone, an item's last `· todo` or
# `· done` that ends its words (never `· done when`).
# - finished counts as completed only with a Next steps section (a summary cut near its cap can
#   lose it), every listed step marked done, the steps in the summary (not `see handoff`), and
#   Step 1 none or proposed; else in-progress;
# - a blocked word counts as in-progress while a step can run (owner xxxxxxxx-08): one marked
#   todo that names no gate, ask, pending answer, wait or needed approval, or Step 1 set with
#   `Gate: none` (Step 1 itself naming none of them). A step whose trigger is a running job's
#   result (`On the timer notification, reply …`, `when CI finishes, …`, `After the run, commit`;
#   owner 2026-10-28 digest rules (a), lane.ts `JOB_RE`) is held on that job, not a step that can
#   run: the copy is taken with no result in, so it stays blocked (only the session's result turn
#   reads it working). A wait whose object is or holds a person (`Wait for the user to run the
#   build`, `wait for the team to run the pipeline`, `wait for the build and the user`) or a step
#   that asks the user (`then ask the user`) is held on the user, whatever job word comes with it.
my $MARK_RE = qr/·\s*(todo|done)(?=\s*$|\s*[;,.)]|\s+\d+\.\s)/m;
my $HELD_RE = qr/\b(?:gated|ask (?:the )?(?:user|owner)|ask you|pending answer|wait(?:s|ing)? (?:on|for|until|till)|await(?:s|ing)?|blocked (?:on|by)|needs? (?:an? )?(?:approval|the user|user|owner|you|your))\b/i;
# lane.ts `JOB_RE` and its parts, word for word.
my $J_WORD = q{(?:(?!(?:of|from|by|for)\s)[\w.#/"`-]+\s+)};
my $J_JOB = q{(?:jobs?|builds?|CI|pipelines?|timers?|agents?|subagents?|workflows?|shells?|runs?|tasks?|tests?|suites?|B-\d+)};
my $J_RESULT = q{(?:results?|outputs?|completion|returns?|notifications?)};
my $J_JOB_RESULT = "(?:notifications?|$J_JOB(?:'s)?\\s+$J_RESULT|(?:results?|outputs?|completion|returns?)\\s+(?:of|from)\\s+(?:(?:the|that|this|its)\\s+)?$J_WORD?$J_JOB)";
my $J_FINISH = q{(?:finish(?:es|ed)?|ends?|ended|completes?|completed|arrives?|arrived|returns?|returned|comes? (?:in|back)|reports? back|reported back|}
    . q{fires?|fired|exits?|exited|pass(?:es|ed)?|fail(?:s|ed)?|succeed(?:s|ed)?|is (?:done|in|back|green|red|over)|are (?:done|in|back|green|red|over))};
my $J_LEAD = q{^(?:\d+\.\s+)?(?:then,?\s+)?};
my $J_WAIT = q{(?:wait(?:s|ing)?\s+(?:on|for|until|till)|await(?:s|ing)?)};
my $JOB_RE = qr/${J_LEAD}(?:on|upon|after)\s+(?:$J_WORD){0,4}?$J_JOB_RESULT\b|${J_LEAD}(?:upon|after)\s+(?:(?:the|that|this|its)\s+)?(?:B-\d+\s+)?$J_JOB\s*[,;:]|${J_LEAD}(?:when|after|once|as soon as)\s+(?:$J_WORD){0,4}?(?:$J_JOB(?:'s)?\s+)?(?:$J_JOB|$J_RESULT)\s+(?:$J_WORD){0,2}?$J_FINISH\b|\b$J_WAIT\s+(?:(?:the|that|this|its)\s+)?(?:$J_WORD){0,2}?(?:$J_JOB_RESULT|$J_JOB)\b/i;
my $USER_RE = qr/\b(?:gated|ask (?:the )?(?:user|owner)|ask you|pending answer|needs? (?:an? )?(?:approval|the user|user|owner|you|your))\b/i;
# lane.ts `PRONOUN`, `PERSON`, `JOB_NOUN`, `WAIT_OBJECT`, `PERSON_WAIT_RE`, `NAMED_WAIT_RE` and
# `waitsOnPerson`, word for word: a wait whose object (up to its clause's end) is or holds a person
# (a pronoun; the user, the owner, a role or group that no job or result follows as a noun; or a
# capitalised name that is no job word or result and that no job or result follows as a noun)
# holds the step on the user, read before $JOB_RE. Helper case AD-11 checks this file's _hold_of
# against the wording lists of plugin/tests/unit/lane.test.ts.
my $J_PRONOUN = q{(?:you|me|him|them|us|someone|somebody|anyone|anybody)};
my $J_PERSON = q{(?:users?|owners?|her|humans?|people|reviewers?|approvers?|maintainers?|teams?|teammates?|clients?|customers?|QA|PMs?|lead|operators?|admins?)};
my $J_JOB_NOUN = q{(?:jobs?|build|CI|pipelines?|timers?|agents?|subagents?|workflows?|shells?|run|tasks?|test|suites?|B-\d+|results?|outputs?|completion|return|notifications?)};
my $J_WAIT_OBJECT = q{(?:(?!\b(?:then|to)\b|[,;:·—]|\.(?:\s|$))[^\n])*?};
my $PERSON_WAIT_RE = qr/\b$J_WAIT\s+$J_WAIT_OBJECT\b(?:$J_PRONOUN(?![\w-])|$J_PERSON(?![\w-])(?!(?:'s)?\s+$J_JOB_NOUN\b))/i;
my $NAMED_WAIT_RE = qr/\b$J_WAIT\s+([A-Za-z]+)\b(?!(?:'s)?\s+$J_JOB_NOUN\b)/i;
my $JOB_WORD_RE = qr/\A(?:$J_JOB|$J_RESULT)\z/i;

sub _waits_on_person {
    my ($text) = @_;
    return 1 if $text =~ $PERSON_WAIT_RE;
    while ($text =~ /$NAMED_WAIT_RE/g) {
        my $w = $1;
        return 1 if $w =~ /\A[A-Z][a-z]+\z/ && $w !~ /\A(?:the|an?|that|this|its|your|our|my)\z/i && $w !~ $JOB_WORD_RE;
    }
    return 0;
}

# What holds a step (lane.ts `holdOf`): 'user', 'job', or undef when it can run.
sub _hold_of {
    my ($text) = @_;
    return 'user' if $text =~ $USER_RE || _waits_on_person($text);
    (my $t = $text) =~ s/\bdone when\b[^·;]*//gi;
    return 'job' if $t =~ $JOB_RE;
    return $text =~ $HELD_RE ? 'user' : undef;
}

sub _trim { my ($s) = @_; $s =~ s/\A\s+|\s+\z//g; return $s }

# (found, lines): the body of the first `## <heading>` section, its heading's inline text first.
sub _section {
    my ($t, $heading) = @_;
    my @lines = split /\n/, $t, -1;
    my $at;
    for my $i (0 .. $#lines) {
        if (lc(_trim($lines[$i])) =~ /\A\Q## $heading\E/) { $at = $i; last }
    }
    return (0) unless defined $at;
    my @out;
    my $head = $lines[$at];
    my $c = index($head, ':');
    push @out, _trim(substr($head, $c + 1)) if $c >= 0 && _trim(substr($head, $c + 1)) ne '';
    for my $l (@lines[$at + 1 .. $#lines]) {
        last if $l =~ /\A#{1,2} / || index($l, '⟪/') == 0 || index($l, '</summary>') == 0;
        push @out, $l;
    }
    return (1, @out);
}

sub _last_mark {
    my ($item) = @_;
    my $mark;
    $mark = $1 while $item =~ /$MARK_RE/g;
    return $mark;
}

# The items of a Next steps section, split as lane.ts `items` splits them.
sub _items {
    my @out;
    for my $raw (@_) {
        my $line = _trim($raw);
        next unless $line =~ /\A(\d+)\.\s/;
        my $next = $1 + 1;
        my $start = 0;
        while ($line =~ /\s(\d+)\.\s/g) {
            my ($n, $at) = ($1, $-[0]);
            next unless $n == $next;
            my $cur = substr($line, $start, $at - $start);
            next unless defined _last_mark($cur);
            push @out, _trim($cur);
            $start = $at + 1;
            $next++;
        }
        push @out, _trim(substr($line, $start));
    }
    return grep { /\A\d+\.\s/ } @out;
}

sub copy_status {
    my ($body) = @_;
    my $t = $body // '';
    utf8::decode($t) unless utf8::is_utf8($t);
    my (undef, @resume) = _section($t, 'resume here');
    my $where = join("\n", @resume);
    $where = $t if $where eq '';
    my ($w) = $where =~ /^\s*Status:\s*([a-z][a-z-]*)/m;
    return 'in-progress' unless defined $w;
    my ($s1) = $where =~ /^\s*Step 1:[ \t]*(.*)$/m;
    my $step = defined $s1 ? _trim($s1) : '';
    my $step1 = $step eq '' ? 'missing' : $step =~ /\A`?none\b/i ? 'none' : $step =~ /\|\s*proposed\s*\z/ ? 'proposed' : 'set';
    my ($g) = $where =~ /^\s*Gate:[ \t]*([^·\n]*)/m;
    $g = defined $g ? _trim($g) : '';
    (my $cmd = $step) =~ s/\s+—\s+for\s+".*\z//;
    my $gate = $g eq '' ? 'missing' : ($g =~ /\A`?none\b/i && !defined _hold_of($cmd)) ? 'none' : 'set';
    my ($listed, @next) = _section($t, 'next steps');
    my ($todo, $unmarked, $free) = (0, 0, 0);
    for my $item (_items(@next)) {
        my $m = _last_mark($item);
        if (!defined $m) { $unmarked++ }
        elsif ($m eq 'todo') { $todo++; $free++ unless defined _hold_of($item) }
    }
    if ($w eq 'finished' || $w eq 'done') {
        return 'in-progress' unless $listed && $todo == 0 && $unmarked == 0 && join("\n", @next) !~ /\bsee handoff\b/i;
        return $step1 eq 'none' || $step1 eq 'proposed' ? 'completed' : 'in-progress';
    }
    if ($w =~ /\A(?:hard-blocked|soft-blocked|blocked|waiting-owner|waiting-job)\z/) {
        return 'in-progress' if $free > 0 || ($step1 eq 'set' && $gate eq 'none');
        return 'blocked';
    }
    return 'in-progress';
}

sub _seq {
    my ($dir, $sid8, $actor_tag) = @_;
    my $n = 0;
    for my $f (util::list_dir($dir)) {
        $n++ if $f =~ /^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_\Q$sid8\E\Q$actor_tag\E_c\d+-/;
    }
    return $n + 1;
}

# session_copies(sid, actor) -> [{path, date, epoch}] across <root>/*/*/compact/
sub session_copies {
    my ($sid, $actor, $extra_bucket) = @_;
    my $root = rc::root();
    my $sid8 = substr($sid, 0, 8);
    my %b;
    for my $repo (util::list_dir($root)) {
        next if $repo =~ /^\./;
        for my $top (util::list_dir("$root/$repo")) {
            next if $top =~ /^\./;
            $b{"$root/$repo/$top"} = 1 if -d "$root/$repo/$top/compact";
        }
    }
    $b{$extra_bucket} = 1 if defined $extra_bucket && -d "$extra_bucket/compact";
    my @out;
    for my $bk (sort keys %b) {
        my $dir = $actor eq 'main' ? "$bk/compact" : "$bk/compact/subagents";
        for my $f (util::list_dir($dir)) {
            next unless $f =~ /^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d_\Q$sid8\E(?:-a[0-9A-Za-z]+)?_c\d+-[0-9a-z-]+\.md$/;
            my $raw = util::read_file("$dir/$f", 8192) // next;
            my ($fm) = frontmatter::read($raw . ($raw =~ /\n---\n/ ? '' : "\n---\n"));
            next unless $fm && ($fm->{session_id} // '') eq $sid;
            next if $actor eq 'main' && ($fm->{actor} // '') ne 'main';
            push @out, { path => "$dir/$f", date => $fm->{date}, epoch => util::parse_iso($fm->{date} // '') // 0, fm => $fm };
        }
    }
    return [sort { $a->{epoch} <=> $b->{epoch} || $a->{path} cmp $b->{path} } @out];
}

sub prev_copy {
    my ($sid, $bucket) = @_;
    my $c = session_copies($sid, 'main', $bucket);
    return @$c ? $c->[-1]{path} : undef;
}

# save(%a) -> {exit, line1, line2, result, path, verdict, id6, sha256}
# a: sid text nonce writer scope agent tokens cwd transcript trigger dispatch
#    seat_state channel precomputed scan verdict_ctx late queue_lane evidence where
#    content_name (the summary repeats an earlier marker: saved under h<sha5> with no
#    nonce, ROOT-RULINGS F2-2)
sub save {
    my (%a) = @_;
    my $sid = $a{sid};
    my $s = $a{scan} || detect::scan($a{text});
    $s->{sha256} //= sha::hex256($s->{normalized});
    my $nonce = $a{content_name} ? undef : nonce::valid($a{nonce}) ? $a{nonce} : $s->{nonce};
    $nonce = undef unless nonce::valid($nonce);
    my $rec = $a{dispatch} // (defined $nonce ? dispatch::read(rc::watch(), $sid, $nonce) : undef);
    my $scope = $a{scope} // 'unknown';
    my %vc = %{ $a{verdict_ctx} || {} };
    $vc{scope} //= $scope;
    $vc{precomputed} //= $a{precomputed};
    my $verdict = $a{verdict} // detect::verdict($s, %vc);
    my $vline = detect::verdict_line($s, $verdict);
    my $id6 = id6($nonce, $s->{sha256});
    my %ret = (verdict => $verdict, id6 => $id6, sha256 => $s->{sha256}, line1 => $vline, nonce => $nonce);

    my $refuse = sub {
        my ($why) = @_;
        rc::emit('copy', [nonce => $nonce, id6 => $id6, result => "failed:$why", slot => undef, rel_path => undef, writer => $a{writer}]);
        return { %ret, exit => 3, result => "failed:$why", line2 => "REFUSED: $why" };
    };
    return $refuse->(rc::root_reason('handoff_root') // 'root-unsafe') unless rc::root_ok('handoff_root');
    return $refuse->('no-watch') unless defined rc::watch();

    my $where = $a{where} || git::where($a{cwd});
    my $bk = bucket::resolve($sid, $a{cwd}, undef, $where);
    my $dir = slot_dir($bk->{path}, $scope);
    my $sid8 = substr($sid, 0, 8);
    my $actor = $scope eq 'main' ? 'main' : $scope eq 'sub' ? ($a{agent} // 'sub-unknown') : 'unknown';
    my $actor_tag = ($scope eq 'sub' && defined $a{agent} && $a{agent} =~ /^[A-Za-z0-9]/) ? '-a' . substr($a{agent}, 0, 8) : '';

    # Secret scan of the summary before writing (S-10): a HARD hit -> redacted copy.
    my $body = $s->{normalized};
    my $redacted;
    my $hits = secrets::scan($body);
    if (secrets::has_hard($hits)) {
        my ($red, $rh) = secrets::redact($body, ['HARD']);
        my $n = 0;
        $n += $_->{count} for @$rh;
        $redacted = sprintf('%d (%s); sha256 %s', $n, secrets::rule_ids($rh), $s->{sha256});
        $body = $red;
    }
    $ret{secret_hits} = [map { $_->{rule} } @$hits];

    my $owner = { sid => $sid, actor => $actor };
    my $sid_dir = rc::sid_dir();
    my $prev = prev_copy($sid, $bk->{path});
    my $lin = sessions::lineage($sid) || {};
    my $c = rc::claude();
    my $tb = ref $a{tokens} eq 'ARRAY' ? $a{tokens}[0] : undef;
    my $ta = ref $a{tokens} eq 'ARRAY' ? $a{tokens}[1] : undef;
    my $out = eval {
        lock::with("$sid_dir/seq.lock", $owner, sub {
            my $cur = $id6;
            for my $try (1 .. 9) {
                my $existing = find($bk->{path}, $cur);
                last unless $existing;
                my ($esha, $efm) = copy_sha($existing);
                # Same id6 from another session or another nonce (6 hex of 8 can repeat)
                # is a true collision, never "already saved": suffix -2, -3, ... (HK-48).
                my $same = ($efm->{session_id} // '') eq $sid && ($efm->{nonce} // '') eq ($nonce // '');
                if ($same && defined $esha && $esha eq $s->{sha256}) {
                    return { kind => 'exists', path => $existing, match => 1, fm => $efm };
                }
                if (!$same || $cur =~ /^h/) { $cur = $id6 . '-' . ($try + 1); next }
                return { kind => 'exists', path => $existing, match => 0, fm => $efm };
            }
            my $seq = $scope eq 'unknown' ? undef : _seq($dir, $sid8, $actor_tag);
            my $stamp = util::file_stamp(util::now());
            my $name = $scope eq 'unknown' ? "${stamp}_${sid8}_$cur.md" : "${stamp}_${sid8}${actor_tag}_c${seq}-$cur.md";
            my $path = "$dir/$name";
            my $fm = frontmatter::write([
                kind                => ($scope eq 'sub' ? 'subagent-summary' : 'compact-summary'),
                writer              => $a{writer},
                nonce               => $nonce,
                date                => util::iso(util::now()),
                session_id          => $sid,
                actor               => $actor,
                previous_session_id => $lin->{previous_session_id},
                lineage_reason      => $lin->{lineage_reason},
                transcript_path     => $a{transcript},
                claude_pid          => $c->{pid},
                cc_version          => rc::cc_version(),
                repository          => $bk->{repo},
                bucket              => $bk->{rel},
                bucket_source       => $bk->{source},
                worktree            => $where->{toplevel},
                branch              => $where->{branch},
                git_commit          => $where->{head},
                status              => copy_status($body),
                queue_lane          => $a{queue_lane},
                previous_handoff    => (defined $prev ? util::abbrev($prev) : undef),
                trigger             => $a{trigger} // ($rec ? $rec->{trigger} : undef),
                compaction_seq      => $seq,
                tokens_before       => $tb,
                tokens_after        => $ta,
                verdict             => $verdict,
                channel             => $a{channel} // ($rec ? $rec->{channel} : 'none'),
                seat_state          => $a{seat_state},
                evidence            => $a{evidence},
                redacted            => $redacted,
                finished_by         => rc::finished_by(),
            ]);
            util::mkdir_p($dir);
            my $ok = util::write_excl($path, $fm . ($body =~ /\n\z/ ? $body : $body . "\n"), 0400);
            return { kind => 'race', path => $path } unless $ok;
            my $back = util::read_file($path);
            my ($pfm) = frontmatter::read($back);
            return { kind => 'failed', why => 'frontmatter-parse', path => $path } unless $pfm && ($pfm->{session_id} // '') eq $sid;
            return { kind => 'saved', path => $path, seq => $seq, id6 => $cur };
        });
    };
    if (!$out) {
        my $e = $@ // 'error';
        my $why = $e =~ /lock-timeout/ ? 'lock-timeout' : 'write-error';
        return $refuse->($why);
    }
    my $rel = substr($out->{path}, length(rc::root()) + 1);
    my $slot = $scope eq 'main' ? 'main' : $scope eq 'sub' ? 'subagents' : 'unattributed';
    if ($out->{kind} eq 'exists') {
        my $result = $out->{match} ? 'exists' : 'mismatch';
        rc::emit('copy', [nonce => $nonce, id6 => $id6, result => $result, slot => $slot, rel_path => $rel, writer => $a{writer}]);
        my $pv = $out->{fm}{verdict};
        if (($a{writer} // '') eq 'mod' && ($out->{fm}{writer} // '') eq 'postcompact-fallback' && defined $pv && $pv ne $verdict) {
            rc::emit('verdict_mismatch', [nonce => $nonce, postcompact => $pv, after_step => $verdict]);
        }
        return { %ret, exit => 0, result => $result, path => $out->{path}, rel => $rel,
                 line2 => 'EXISTS: ' . util::abbrev($out->{path}) . ($out->{match} ? ' sha-match' : ' sha-differs') };
    }
    return $refuse->($out->{why} // 'race') unless $out->{kind} eq 'saved';
    my $result = $a{late} ? 'late' : $scope eq 'unknown' ? 'unattributed' : 'saved';
    rc::emit('copy', [nonce => $nonce, id6 => $out->{id6}, result => $result, slot => $slot, rel_path => $rel, writer => $a{writer},
                      seq => $out->{seq}, redacted => (defined $redacted ? jsonc::true() : jsonc::false()), (defined $a{proof} ? (proof => $a{proof}) : ())]);
    rc::emit('verdict', [nonce => $nonce, verdict => $verdict, verdict_source => (($a{writer} // '') eq 'mod' ? 'after-step' : 'postcompact'),
                         marker_line => $s->{marker_line}, sentinel_from_end => $s->{sentinel_from_end}]);
    return { %ret, exit => 0, result => $result, path => $out->{path}, rel => $rel, seq => $out->{seq}, id6 => $out->{id6},
             line2 => 'Saved copy: ' . util::abbrev($out->{path}), bucket => $bk };
}

1;

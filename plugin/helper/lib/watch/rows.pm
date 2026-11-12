package watch::rows;
# lib/watch/rows.pm: classify one transcript row by key, never by position.
# Text is read in memory to
# compute classes and is dropped; the result holds ids, counts and classes.
use strict;
use warnings;
use utf8;
use watch::io;
use watch::spec;
use watch::json;

our $SUMMARY_HEAD = 'This session is being continued from a previous conversation';
# 0.1.4 (A-27): the words every handoff-turn submit of the plugin carries (assets/handoff-turn.txt,
# its [submit-halt], [submit-pre] and [submit-idle] lines), never a continue
our $HT_SUBMIT = ', so the plugin asks for a handoff while the context is still here.';

# The read-only Bash class.
my $READONLY_BASH = qr/\A\s*(?:git\s+(?:status|log|diff|show|rev-parse|branch)\b|ls\b|rg\b|head\b|tail\b|wc\b|date\b)/;
my %PROGRESS_TOOLS = map { $_ => 1 } qw(Edit Write NotebookEdit);
my %SPAWN_TOOLS = map { $_ => 1 } qw(Agent Task Workflow);
my %HEAL_TOOLS = map { $_ => 1 } qw(SendMessage TaskStop Monitor CronCreate);

sub _text_of {
    my ($content) = @_;
    return $content if defined $content && !ref $content;
    my $t = '';
    if (ref $content eq 'ARRAY') {
        for my $c (@$content) {
            if (!ref $c) { $t .= $c }
            elsif (ref $c eq 'HASH' && ($c->{type} // '') eq 'text' && defined $c->{text}) { $t .= $c->{text} }
        }
    }
    return $t;
}

sub ts_of { return watch::io::parse_iso($_[0]{timestamp}) }

# Classes of one Bash command (spec `outward_classes`), and the read-only test.
sub bash_classes {
    my ($cmd, $outward) = @_;
    my @c;
    for my $cl (@$outward) { push @c, $cl->[0] if $cmd =~ $cl->[1] }
    return \@c;
}

# The spec's protected_branch_re, compiled by the sweep for its run;
# undef = no check. $PROTECTED_USER: the compiled entries of the user's
# add-only protected_branches setting, matched the same way, beside the spec's list. $PROTECTED_BOUNDED (U-06):
# the user's entries that mix `*` and `**`, as settings::protected returns them; settings::protected_user
# matches them with a time bound (a stopped one counts as protected).
our $PROTECTED_RE;
our $PROTECTED_USER = [];
our $PROTECTED_BOUNDED;

# 1 when a git push in the command names a protected destination: a refspec's destination (or
# the ref named) matching protected_branch_re or one of the user's entries, lower-cased, or
# --all, --mirror, --branches. A push with no refspec goes to a branch the transcript does not
# show: 0 (the watcher has no git state). Quotes and backslashes are removed first, as the shell
# would.
sub push_protected {
    my ($cmd, $pre, $user) = @_;
    my @user = grep { ref $_ eq 'Regexp' } @{ ref $user eq 'ARRAY' ? $user : [] };
    my $bounded = ref $PROTECTED_BOUNDED eq 'HASH' && ref $PROTECTED_BOUNDED->{globs} eq 'ARRAY' && @{ $PROTECTED_BOUNDED->{globs} }
                  && defined &settings::protected_user ? $PROTECTED_BOUNDED : undef;
    return 0 unless (defined $pre || @user || $bounded) && defined $cmd;
    (my $c = $cmd) =~ s/\\(.)/$1/gs;
    $c =~ tr/"'//d;
    for my $seg (split /\|\||&&|[|;&\n]/, $c) {
        my @w = split ' ', $seg;
        my ($gi) = grep { lc($w[$_]) eq 'git' } 0 .. $#w;
        next unless defined $gi;
        my ($pi) = grep { $w[$_] eq 'push' } $gi + 1 .. $#w;
        next unless defined $pi;
        my @a = @w[$pi + 1 .. $#w];
        return 1 if grep { /\A--(?:all|mirror|branches)\z/ } @a;
        my @pos = grep { !/\A-/ } @a;
        shift @pos;
        for my $rs (@pos) {
            my $d = $rs =~ /:/ ? (split /:/, $rs, 2)[1] : $rs;
            $d =~ s/\A\+//;
            $d =~ s{\Arefs/heads/}{};
            next if $d eq '';
            return 1 if (defined $pre && lc($d) =~ $pre) || grep { lc($d) =~ $_ } @user;
            return 1 if $bounded && defined settings::protected_user($d, $bounded);
        }
    }
    return 0;
}

# Facts of one decoded row. `brand` is the plugin name; `outward` the compiled
# outward classes.
sub classify {
    my ($r, $brand, $outward) = @_;
    my %f = (type => ($r->{type} // ''), uuid => $r->{uuid}, ts => ts_of($r), sid => $r->{sessionId});
    my $type = $f{type};
    if ($type eq 'system' && ($r->{subtype} // '') eq 'compact_boundary') {
        my $m = ref $r->{compactMetadata} eq 'HASH' ? $r->{compactMetadata} : {};
        $f{kind} = 'boundary';
        $f{trigger} = $m->{trigger};
        $f{pre} = $m->{preTokens};
        $f{post} = $m->{postTokens};
        $f{duration_ms} = $m->{durationMs};
        $f{precomputed} = $m->{precomputed} ? 1 : 0;
        $f{dropped} = $m->{cumulativeDroppedTokens};
        $f{preserved_segment} = ref $m->{preservedSegment} eq 'HASH' ? 1 : 0;
        $f{version} = $r->{version};
        return \%f;
    }
    if (exists $r->{apiError} || $r->{isApiErrorMessage}) {
        my $msg = ref $r->{message} eq 'HASH' ? _text_of($r->{message}{content}) : '';
        my $e = defined $r->{apiError} && !ref $r->{apiError} ? $r->{apiError} : '';
        my $all = "$e $msg";
        $f{kind} = 'api_error';
        $f{error_class} = $all =~ /autocompact_thrash/i ? 'thrash'
                        : $all =~ /Error compacting conversation/i ? 'compact'
                        : $all =~ /prompt is too long|prompt[-_ ]too[-_ ]long/i ? 'prompt-too-long'
                        : 'other';
        return \%f;
    }
    if ($type eq 'attachment' && ref $r->{attachment} eq 'HASH') {
        my $a = $r->{attachment};
        my $at = $a->{type} // '';
        if ($at eq 'task_status') {
            $f{kind} = 'task_status';
            $f{task_id} = $a->{taskId};
            $f{task_type} = $a->{taskType};
            $f{status} = $a->{status};
            $f{output_known} = defined $a->{outputFilePath} ? 1 : 0;
            return \%f;
        }
        if ($at eq 'hook_additional_context') {
            my $text = _text_of($a->{content});
            $f{kind} = 'hook_context';
            $f{hook_event} = $a->{hookEvent};
            if (defined $brand && ($a->{hookEvent} // '') eq 'PostToolUse'
                && index($text, "Note from the user's $brand plugin:") == 0) {
                $f{kind} = 'nudge';
            }
            return \%f;
        }
        $f{kind} = 'attachment';
        return \%f;
    }
    if ($type eq 'user') {
        my $msg = ref $r->{message} eq 'HASH' ? $r->{message} : {};
        my $content = $msg->{content};
        if (ref $content eq 'ARRAY' && grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$content) {
            $f{kind} = 'tool_result';
            $f{results} = [ map { { id => $_->{tool_use_id}, is_error => ($_->{is_error} ? 1 : 0),
                                    timed_out => (_text_of($_->{content}) =~ /timed out/i ? 1 : 0) } }
                            grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$content ];
            # 0.1.4 (A-11): a background workflow's launch result names its task id and its run, the
            # folder of the run journal (ids only)
            my $u = ref $r->{toolUseResult} eq q(HASH) ? $r->{toolUseResult} : undef;
            if ($u && ($u->{taskType} // q()) eq q(local_workflow) && defined $u->{taskId} && !ref $u->{taskId} && $u->{taskId} =~ /\A[0-9A-Za-z_-]{1,64}\z/
                && defined $u->{runId} && !ref $u->{runId} && $u->{runId} =~ /\A[0-9A-Za-z_-]{1,64}\z/) {
                $f{wf_task} = [ $u->{taskId}, $u->{runId} ];
            }
            return \%f;
        }
        my $text = _text_of($content);
        if (index($text, $SUMMARY_HEAD) == 0) {
            $f{kind} = 'summary';
            $f{is_compact_summary} = $r->{isCompactSummary} ? 1 : 0;
            $f{visible_only} = $r->{isVisibleInTranscriptOnly} ? 1 : 0;
            $f{chars} = length $text;
            return \%f;
        }
        my $origin = ref $r->{origin} eq 'HASH' ? $r->{origin} : undef;
        if ($origin && ($origin->{kind} // '') eq 'plugin') {
            $f{kind} = (defined $brand && ($origin->{name} // '') eq $brand) ? 'continue' : 'plugin_prompt';
            # the plugin's handoff-turn submit, told by its text when its ht record is gone
            $f{ht_submit} = 1 if $f{kind} eq 'continue' && index($text, "Note from the user's $brand plugin: ") >= 0
                                && index($text, $HT_SUBMIT) >= 0;
            return \%f;
        }
        if ($r->{isMeta}) { $f{kind} = 'meta'; return \%f }
        $f{kind} = 'prompt';
        if (defined $brand) {
            my $q = quotemeta("/$brand:resume");
            if ($text =~ /\A\s*$q(?:\s|\z)/ || $text =~ /<command-name>$q<\/command-name>/) {
                $f{resume_invocation} = 1;
                $f{resume_args} = ($text =~ /\A\s*$q\s+\S/ || $text =~ /<command-args>\s*\S/) ? 1 : 0;
            }
        }
        return \%f;
    }
    if ($type eq 'assistant') {
        my $msg = ref $r->{message} eq 'HASH' ? $r->{message} : {};
        my @uses = grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_use' } @{ ref $msg->{content} eq 'ARRAY' ? $msg->{content} : [] };
        $f{kind} = 'assistant';
        $f{text_only} = @uses ? 0 : 1;
        my @calls;
        for my $u (@uses) {
            my $name = defined $u->{name} && !ref $u->{name} ? $u->{name} : 'other';
            my $in = ref $u->{input} eq 'HASH' ? $u->{input} : {};
            my %c = (id => $u->{id}, name => ($name =~ /\A[A-Za-z0-9_.:-]{1,80}\z/ ? $name : 'other'));
            if ($name eq 'Bash') {
                my $cmd = defined $in->{command} && !ref $in->{command} ? $in->{command} : '';
                $c{outward} = bash_classes($cmd, $outward || []);
                $c{protected} = 1 if ($PROTECTED_RE || @{ $PROTECTED_USER || [] }
                                      || (ref $PROTECTED_BOUNDED eq 'HASH' && @{ $PROTECTED_BOUNDED->{globs} || [] }))
                                     && grep({ $_ eq 'push' || $_ eq 'force-push' } @{ $c{outward} })
                                     && push_protected($cmd, $PROTECTED_RE, $PROTECTED_USER);
                $c{readonly} = $cmd =~ $READONLY_BASH ? 1 : 0;
                if (defined $brand) {
                    my $store = quotemeta($brand . '-store');
                    if ($cmd =~ /(?:\A|[\s\/])$store\s+heal-check\b/) { $c{heal} = 1 }
                    elsif ($cmd =~ /(?:\A|[\s\/])$store\s+(?:locate|measure|verify|inventory)\b/) { $c{readonly} = 1 }
                }
                $c{progress} = ($c{readonly} || $c{heal}) ? 0 : 1;
            } elsif ($PROGRESS_TOOLS{$name}) {
                $c{progress} = 1;
            } elsif ($name eq 'Workflow' && defined $in->{resumeFromRunId}) {
                $c{heal} = 1;
            } elsif ($SPAWN_TOOLS{$name}) {
                $c{progress} = 1;
                $c{spawn} = 1;
            } elsif ($HEAL_TOOLS{$name}) {
                $c{heal} = 1;
                if ($name eq 'TaskStop') {
                    my $id = $in->{task_id} // $in->{taskId} // $in->{id};
                    $c{stop_id} = $id if defined $id && !ref $id && $id =~ /\A[A-Za-z0-9_.:-]{1,80}\z/;
                }
            } elsif ($name eq 'AskUserQuestion') {
                $c{ask} = 1;
            } elsif ($name =~ /\Amcp__/) {
                $c{mcp} = 1;
                $c{outward} = bash_classes($name, $outward || []);
            }
            push @calls, \%c;
        }
        $f{calls} = \@calls;
        return \%f;
    }
    $f{kind} = 'other';
    return \%f;
}

# Read up to $max bytes from the end of a file; returns whole lines only.
sub tail_rows {
    my ($path, $max, $brand, $outward) = @_;
    return [] unless defined $path && -f $path;
    open(my $fh, '<:raw', $path) or return [];
    my $size = -s $fh;
    my $from = $size > $max ? $size - $max : 0;
    seek($fh, $from, 0);
    local $/ = "\n";
    <$fh> if $from > 0;
    my @out;
    while (my $line = <$fh>) {
        last unless $line =~ /\n\z/;
        my $r = eval { watch::json::decode($line) };
        next unless ref $r eq 'HASH';
        push @out, classify($r, $brand, $outward);
    }
    close $fh;
    return \@out;
}

1;

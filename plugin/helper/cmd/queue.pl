# cmd/queue.pl: `queue check [<program>]` (0.1.6: a way to check a queue tool against the
# queue contract and how to connect to it).
# Runs the read-only part of the queue_cmd contract (assets/queue-contract.md) against <program>,
# default the queue_cmd setting: `list --json --session <made-up id>` once, through queue::call
# as the plugin runs it (5 s), and checks the file, the exit code, the time, the JSON, the
# schema tag, each key against assets/queue-stub.v1.schema.json (check_value: the keywords that
# file uses), that `session` is the id it sent, and the commands list. Prints one line per check, `ok|FAIL|skip|note <check>
# (<what>)`, a FAIL line ending `; fix: <fix>`, then `QUEUE CHECK PASS` (exit 0) or `QUEUE CHECK
# FAIL <first failed check>` (exit 1). Never calls add or adopt: they write and the contract has
# no dry run. Writes nothing: no queue-state.json, no caps cache, no row (queue::lane is not used).
# Exit codes: 0, 1, 64 (usage), 70.
use strict;
use warnings;
use utf8;

package cmd_queue;

our $SID = '00000000-0000-4000-8000-00000000c0de';
our $WAIT_MS = 5000;    # the plugin's longest list wait (a checkpoint, begin)
our $FAST_MS = 1500;    # its shortest (the local comparison trial); 3 s after a compaction
our $MAX_OUT = 256 * 1024;
my $USAGE = 'usage: queue check [<program>]';

# The JSON type of a decoded value: null, boolean, object, array, integer, number or string.
sub _type {
    my ($v) = @_;
    return 'null' unless defined $v;
    return 'boolean' if jsonc::is_bool($v);
    return 'object' if ref $v eq 'HASH';
    return 'array' if ref $v eq 'ARRAY';
    return 'other' if ref $v;
    return 'string' unless jsonc::_is_number($v);
    return $v =~ /\A-?[0-9]+\z/ ? 'integer' : 'number';
}

sub _show { my ($v) = @_; return jsonc::encode($v) }

# _shq(text) -> text single-quoted for a POSIX shell, so a printed fix runs as printed (a full
# path: `~` inside quotes is not expanded)
sub _shq { my ($t) = @_; $t =~ s/'/'\\''/g; return "'$t'" }

sub _same {
    my ($a, $b) = @_;
    my ($ta, $tb) = (_type($a), _type($b));
    return 0 unless $ta eq $tb || ($ta =~ /integer|number/ && $tb =~ /integer|number/);
    return 1 if $ta eq 'null';
    return ($a ? 1 : 0) == ($b ? 1 : 0) ? 1 : 0 if $ta eq 'boolean';
    return 0 if ref $a || ref $b;
    return "$a" eq "$b" ? 1 : 0;
}

# check_value(value, schema) -> undef when value meets schema, else what is wrong (one phrase).
# The keywords of the queue schema files: const, enum, type, anyOf, pattern, minLength,
# maxLength, minimum, items, minItems, maxItems, required, properties. A pattern's final `$`
# means the end of the text (as in JSON Schema), not "before a final newline".
sub check_value {
    my ($v, $s) = @_;
    return undef unless ref $s eq 'HASH';
    return 'is ' . _show($v) . ', not ' . _show($s->{const}) if exists $s->{const} && !_same($v, $s->{const});
    if (ref $s->{enum} eq 'ARRAY' && !grep { _same($v, $_) } @{ $s->{enum} }) {
        return 'is ' . _show($v) . ', not one of ' . join(', ', map { _show($_) } @{ $s->{enum} });
    }
    my $t = _type($v);
    if (defined $s->{type}) {
        my @want = ref $s->{type} eq 'ARRAY' ? @{ $s->{type} } : ($s->{type});
        return "is $t, not " . join(' or ', @want) unless grep { $_ eq $t || ($_ eq 'number' && $t eq 'integer') } @want;
    }
    if (ref $s->{anyOf} eq 'ARRAY') {
        my @why = map { check_value($v, $_) } @{ $s->{anyOf} };
        if (!grep { !defined } @why) {
            # each branch wants another type: one phrase, "is string, not integer or array"
            my @t = map { /\Ais \Q$t\E, not (.+)\z/ ? $1 : () } @why;
            return "is $t, not " . join(' or ', @t) if @t == @why;
            return join('; or it ', @why);
        }
    }
    if ($t eq 'string') {
        if (defined $s->{pattern}) {
            (my $re = $s->{pattern}) =~ s/(?<!\\)\$\z/\\z/;
            return 'does not match ' . $s->{pattern} unless $v =~ /$re/;
        }
        return 'is empty' if defined $s->{minLength} && length($v) < $s->{minLength};
        return 'is ' . length($v) . " characters, over $s->{maxLength}" if defined $s->{maxLength} && length($v) > $s->{maxLength};
    }
    if ($t eq 'integer' || $t eq 'number') {
        return "is below $s->{minimum}" if defined $s->{minimum} && $v < $s->{minimum};
    }
    if ($t eq 'array') {
        return 'has fewer than ' . $s->{minItems} . ' items' if defined $s->{minItems} && @$v < $s->{minItems};
        return 'has more than ' . $s->{maxItems} . ' items' if defined $s->{maxItems} && @$v > $s->{maxItems};
        if (ref $s->{items} eq 'HASH') {
            for my $i (0 .. $#$v) {
                my $w = check_value($v->[$i], $s->{items});
                return "item $i $w" if defined $w;
            }
        }
    }
    if ($t eq 'object') {
        for my $k (@{ ref $s->{required} eq 'ARRAY' ? $s->{required} : [] }) {
            return "lacks \"$k\"" unless exists $v->{$k};
        }
        my $p = ref $s->{properties} eq 'HASH' ? $s->{properties} : {};
        for my $k (sort keys %$p) {
            next unless exists $v->{$k};
            my $w = check_value($v->{$k}, $p->{$k});
            return "\"$k\" $w" if defined $w;
        }
    }
    return undef;
}

sub run {
    my $sub = shift @_;
    die "$USAGE\n" unless defined $sub && $sub eq 'check';
    my ($opt, $rest) = args::parse(\@_, known => [qw(root log-dir)]);
    die "$USAGE\n" if @$rest > 1;
    rc::init(sid => undef, writer => 'helper', flags => settings::flags_from($opt));
    my $cmd = @$rest ? $rest->[0] : rc::val('queue_cmd');
    my $from = @$rest ? 'argument' : 'queue_cmd';
    if (@$rest && $cmd ne '' && $cmd !~ m{\A/}) {
        require File::Spec;
        $cmd = File::Spec->rel2abs($cmd);
    }
    my (@lines, $fail);
    my $say = sub {
        my ($st, $name, $what, $fix) = @_;
        push @lines, "$st $name" . (defined $what ? " ($what)" : '') . (defined $fix ? "; fix: $fix" : '');
        $fail //= $name if $st eq 'FAIL';
    };
    my $done = sub {
        $say->('note', 'not checked', 'add and adopt: they write, and the contract has no dry run; assets/queue-contract.md, Testing');
        args::out(@lines, defined $fail ? "QUEUE CHECK FAIL $fail" : 'QUEUE CHECK PASS');
        return defined $fail ? 1 : 0;
    };
    my $skip = sub { $say->('skip', 'list', $_[0]); return $done->() };
    # the setting's own notes, as status prints them (a consent key: `safe value used` when HOME
    # or CLAUDE_CONFIG_DIR is not the account's, `settings file only`), so an ignored value says why
    if ($from eq 'queue_cmd') {
        $say->('note', 'queue_cmd', util::text($_)) for map { /\Aqueue_cmd: (.+)\z/s ? $1 : () } @{ rc::settings()->{notes} || [] };
    }

    # the file
    my $show = defined $cmd ? util::text(util::abbrev($cmd)) : undef;
    if (!defined $cmd || $cmd eq '') {
        $say->('FAIL', 'program', 'queue_cmd is empty and no program was given',
               "pass the program's path, or set queue_cmd (README, \"Connect your own question queue\")");
        return $skip->('no program');
    }
    if ($cmd !~ m{\A/}) {
        $say->('FAIL', 'program', "queue_cmd $show is not a full path", 'set queue_cmd to the full path, starting with /');
        return $skip->('no program');
    }
    if (!-e $cmd) { $say->('FAIL', 'program', "no file at $show", 'check the path'); return $skip->('no program') }
    if (!-f _) { $say->('FAIL', 'program', "$show is not a file", 'name the program file itself'); return $skip->('no program') }
    if (!-x _) { $say->('FAIL', 'program', "$show is not executable", 'chmod +x ' . _shq(util::text($cmd))); return $skip->('the program cannot run') }
    $say->('ok', 'program', $show . ($from eq 'queue_cmd' ? ', from queue_cmd' : ''));

    # list, as the plugin runs it
    my $t0 = util::clock_ms();
    # one byte over the plugin's cap, so a reply of exactly 256 KiB passes and a longer one is seen
    my $r = queue::call([$cmd, 'list', '--json', '--session', $SID], $WAIT_MS, $MAX_OUT + 1);
    my $ms = util::clock_ms() - $t0;
    if ($r->{timed_out}) {
        $say->('FAIL', 'list-time', "no answer in $WAIT_MS ms", 'answer list within 1.5 s: read only your own store, no network call');
        return $done->();
    }
    if (($r->{exit} // -1) != 0) {
        my $x = $r->{exit} // -1;
        $say->('FAIL', 'list-exit', "list --json --session $SID: exit $x" . ($x == 127 ? ', or the program did not start' : ''),
               $x == 127 ? 'start the file with a #! line naming its interpreter, for example #!/bin/sh'
                         : 'exit 0 with a reply for any session id, also one the program has never seen (list only reads)');
        return $done->();
    }
    $say->('ok', 'list-exit', 'exit 0');
    if ($ms > $FAST_MS) {
        $say->('FAIL', 'list-time', "$ms ms, over $FAST_MS ms",
               'answer list within 1.5 s, the plugin\'s shortest wait (3 s after a compaction, 5 s at a checkpoint)');
    } else {
        $say->('ok', 'list-time', "$ms ms, limit $FAST_MS ms");
    }

    my $out = $r->{out} // '';
    my $j = eval { jsonc::decode(util::text($out)) };
    my $err = $@;
    if (length($out) > $MAX_OUT) {
        $say->('FAIL', 'list-json', 'the reply is over 256 KiB', 'print one JSON object of at most 256 KiB');
        return $done->();
    }
    if (ref $j ne 'HASH') {
        my $what = $out !~ /\S/ ? 'nothing on stdout' : defined $j || $err eq '' ? 'JSON ' . _type($j) . ', not an object'
                 : do { (my $e = $err) =~ s/\s+\z//; "not JSON: $e" };
        $say->('FAIL', 'list-json', $what, 'print one JSON object on stdout and nothing else; write any log to stderr');
        return $done->();
    }
    $say->('ok', 'list-json', 'one object, ' . length($out) . ' bytes');
    if (!exists $j->{schema}) {
        $say->('FAIL', 'list-schema', 'no "schema" key: the plugin reads nothing from the reply, queue: degraded (untagged)',
               'add "schema": "queue-stub/v1"');
        return $done->();
    }
    if (!_same($j->{schema}, 'queue-stub/v1')) {
        $say->('FAIL', 'list-schema', '"schema" is ' . _show($j->{schema}) . ': the plugin reads nothing from the reply, queue: degraded (schema)',
               'set "schema" to "queue-stub/v1"');
        return $done->();
    }
    $say->('ok', 'list-schema', 'queue-stub/v1');

    # every key against the shipped schema
    my $sraw = util::read_file(ctx::asset_path('queue-stub.v1.schema.json'));
    my $sch = defined $sraw ? eval { jsonc::decode($sraw) } : undef;
    if (ref $sch ne 'HASH' || ref $sch->{properties} ne 'HASH') {
        $say->('FAIL', 'list-keys', 'assets/queue-stub.v1.schema.json is missing or unreadable', 'reinstall the plugin');
        return $done->();
    }
    my $props = $sch->{properties};
    my @req = @{ ref $sch->{required} eq 'ARRAY' ? $sch->{required} : [] };
    my %req = map { $_ => 1 } @req;
    my (%bad, @seen);
    for my $k (@req, sort grep { !$req{$_} } keys %$props) {
        my $desc = ref $props->{$k} eq 'HASH' ? $props->{$k}{description} : undef;
        my $fix = defined $desc ? "\"$k\" must be $desc" : undef;
        if (!exists $j->{$k}) {
            next unless $req{$k};
            $say->('FAIL', 'list-keys', "no \"$k\"", "add \"$k\"" . (defined $desc ? ": $desc" : ''));
            $bad{$k} = 1;
            next;
        }
        my $w = check_value($j->{$k}, $props->{$k});
        # the contract's `session`: the --session value (the schema cannot name it)
        $w = 'is ' . _show($j->{$k}) . ", not the --session value $SID" if !defined $w && $k eq 'session' && $j->{$k} ne $SID;
        if (defined $w) { $say->('FAIL', 'list-keys', "\"$k\" $w", $fix); $bad{$k} = 1; next }
        push @seen, $k;
    }
    $say->('ok', 'list-keys', join(', ', @seen)) unless %bad;
    if (!exists $j->{commands}) {
        $say->('note', 'commands', 'none listed: the plugin calls list and adopt, never add');
    } elsif (!$bad{commands}) {
        my @c = grep { defined && !ref } @{ $j->{commands} };
        $say->('ok', 'commands', join(', ', @c) . ((grep { $_ eq 'add' } @c) ? '' : '; no add: the plugin queues no question'));
    }
    return $done->();
}

exit(args::main(\&run, @ARGV));

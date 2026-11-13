package settings_write;
# lib/settings_write.pm: the plugin's one writer of the user's settings file (0.1.2: one helper
# writer, safe keys only). `settings set` and
# `settings reset` (cmd/settings.pl) both plan and apply through it.
#
# What it may change: pluginConfigs["<plugin>@<marketplace>"].options in
# ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json, one member per key of this plugin, and nothing
# else. What it refuses, with nothing written:
#   - the six consent keys (%settings::FILE_ONLY) on every path, set and reset alike: the helper
#     cannot tell a command the user typed (`!`) from one the model ran, so it never writes them;
#     consent_lines() gives the user-run ways (/config, Claude Code's own `plugin configure`);
#   - a value the plugin would not read as written (check_value: the manifest's type, min and max,
#     the enum values, the list rules of each pattern key, a path that is not absolute). A number
#     the clamp lowers against the other keys (the soft max and target against the window, the
#     target against the soft max) is not refused: it is written with a note (clamp_notes), as
#     the clamp's window is often the model's, known only at run time;
#   - a looser protective value: the three protective lists only gain entries (a command cannot
#     replace a list with a shorter one, as for flags), resume_proceed only goes towards confirm;
#   - a settings file the view (settings::write_refused) refuses: another settings folder, an
#     unreadable file, one that is not plain JSON or whose plugin entry is not an object, an
#     @inline (--plugin-dir) run, two keys for the plugin; also a missing file, a member named
#     twice on the path, a hard-linked file (the rename would split its names), a file that
#     changed since the dry run (--plan) or between the read and the write.
# Setting a key to its default (or to "") removes the member: a default is never written, so a
# later release's default still applies.
#
# The write is a text edit of exactly those members (a value replaced, a member removed with one
# separator, a member inserted after the last one with that member's spacing, a missing options,
# entry or pluginConfigs object created), so every other byte of the file stays: jsonc::decode
# returns unordered hashes and encode_pretty sorts keys, so a re-encode would reorder the user's
# whole file. Before the rename: the new text must decode to the old settings with exactly those
# changes (a JSON round trip of every other key), a backup of the whole file is written next to it
# (settings.json.<plugin>-<stamp>.bak, mode 0600, never pruned), and the file is read again and
# must still hold the bytes the plan read. A backup that fails partway is removed (no partial
# backup is left). The new text goes to a temp file in the real file's folder with the file's
# mode, then a rename (a symlinked settings.json keeps its link); a failed write removes the temp
# file, so no partial file is left. Then the file is read once more and must hold the new bytes.
# Inserted lines use the file's own line break (\r\n in a file that has one, else \n).
# Test seams (STORE_TEST_MODE=1 only): STORE_TEST_SETTINGS_RACE=<text> writes that text over the
# settings file right after the backup (another program writing it then);
# STORE_TEST_SETTINGS_FAIL=write fails the temp file's write halfway (a full disk), =backup the
# backup's write.
use strict;
use warnings;
use utf8;
use Fcntl ();
require Cwd;

our $VALUE_MAX = 4096;      # bytes of one value
our $NUM_MAX = 1e15;        # larger numbers print as 1e+15, which the plugin does not read
our $LIST_MAX = 32;         # entries of a pattern list (the readers' own limit)
our $LIST_LEN = 200;        # characters of one pattern entry

# ---------------------------------------------------------------- the member scanner
# The text is valid JSON here (jsonc::decode took it first). Positions are byte offsets.
sub _ws { my ($t, $p) = @_; pos($$t) = $p; $$t =~ /\G[ \t\r\n]*/gc; return pos($$t) }

# _skip(text ref, pos) -> the offset just after the value that starts at pos (after white space)
sub _skip {
    my ($t, $p) = @_;
    $p = _ws($t, $p);
    my $c = substr($$t, $p, 1);
    if ($c eq '"') { pos($$t) = $p; $$t =~ /\G"(?:[^"\\]|\\.)*"/gcs or die "scan: string at $p\n"; return pos($$t) }
    if ($c eq '{' || $c eq '[') {
        my $close = $c eq '{' ? '}' : ']';
        $p = _ws($t, $p + 1);
        return $p + 1 if substr($$t, $p, 1) eq $close;
        while (1) {
            if ($c eq '{') { $p = _skip($t, $p); $p = _ws($t, $p); $p++ }    # the key, then ':'
            $p = _ws($t, _skip($t, $p));
            my $d = substr($$t, $p, 1);
            return $p + 1 if $d eq $close;
            die "scan: expected , at $p\n" unless $d eq ',';
            $p = _ws($t, $p + 1);
        }
    }
    pos($$t) = $p;
    $$t =~ /\G[^,\]\}\s]+/gc or die "scan: value at $p\n";
    return pos($$t);
}

# _members(text ref, pos of `{`) -> ([{key, kstart, kend, vstart, vend}], close offset)
sub _members {
    my ($t, $o) = @_;
    my @m;
    my $p = _ws($t, $o + 1);
    return ([], $p) if substr($$t, $p, 1) eq '}';
    while (1) {
        my $ks = $p;
        my $ke = _skip($t, $p);
        my $key = jsonc::decode(substr($$t, $ks, $ke - $ks));
        $p = _ws($t, $ke) + 1;    # ':'
        my $vs = _ws($t, $p);
        my $ve = _skip($t, $vs);
        push @m, { key => $key, kstart => $ks, kend => $ke, vstart => $vs, vend => $ve };
        $p = _ws($t, $ve);
        my $d = substr($$t, $p, 1);
        return (\@m, $p) if $d eq '}';
        $p = _ws($t, $p + 1);
    }
}

# _find(text ref, options key) -> ({root, pc, entry, opts: the offset of each object's `{`, undef
# when the member is missing}) or (undef, why): twice:<name> for a member named twice on the path
# or in the options object, unparseable for a member on the path that is not an object.
sub _find {
    my ($t, $ckey) = @_;
    my %at = (root => _ws($t, 0));
    return (undef, 'not-json') unless substr($$t, $at{root}, 1) eq '{';
    my $p = $at{root};
    for my $step (['pc', 'pluginConfigs'], ['entry', $ckey], ['opts', 'options']) {
        my ($m) = _members($t, $p);
        my @hit = grep { $_->{key} eq $step->[1] } @$m;
        return (undef, "twice:$step->[1]") if @hit > 1;
        return (\%at) unless @hit;
        $p = $hit[0]{vstart};
        return (undef, 'unparseable') unless substr($$t, $p, 1) eq '{';
        $at{ $step->[0] } = $p;
    }
    my ($m) = _members($t, $at{opts});
    my %n;
    for (@$m) { return (undef, "twice:$_->{key}") if $n{ $_->{key} }++ }
    return (\%at);
}

# ---------------------------------------------------------------- text edits
sub _line_indent {
    my ($t, $p) = @_;
    my $ls = rindex($$t, "\n", $p) + 1;
    return substr($$t, $ls, $p - $ls) =~ /\A([ \t]*)/ ? $1 : '';
}

# The file's line break: the first one in it (\r\n or \n), else \n.
sub _nl { my ($t) = @_; return $$t =~ /(\r?\n)/ ? $1 : "\n" }

# The file's indent step: the white space before its first member, else two spaces.
sub _unit {
    my ($t) = @_;
    my $root = _ws($t, 0);
    my $first = _ws($t, $root + 1);
    my $gap = substr($$t, $root + 1, $first - $root - 1);
    return $gap =~ /\n([ \t]+)\z/ ? $1 : '  ';
}

sub _key_json { return jsonc::encode_bytes($_[0]) }

# _nest([names], leaf value text, indent or undef, indent step, line break) -> the text of
# {n1: {n2: … leaf}}, as many levels as names (the leaf alone for none); multi-line at that
# indent, one line for undef.
sub _nest {
    my ($names, $leaf, $ind, $unit, $nl) = @_;
    return $leaf unless @$names;
    my ($first, @rest) = @$names;
    my $in = defined $ind ? $ind . $unit : undef;
    my $inner = _nest(\@rest, $leaf, $in, $unit, $nl);
    return defined $ind ? "{$nl$in" . _key_json($first) . ": $inner$nl$ind}" : '{' . _key_json($first) . ": $inner}";
}

# _insert(text ref, offset of an object's `{`, [names], leaf value text): a member names[0] whose
# value nests the rest down to the leaf, after the object's last member with that member's
# separator and spacing, or as the only member of an empty object.
sub _insert {
    my ($t, $open, $names, $leaf) = @_;
    my ($first, @rest) = @$names;
    my $unit = _unit($t);
    my $nl = _nl($t);
    my ($m, $close) = _members($t, $open);
    if (@$m) {
        my $last = $m->[-1];
        my $prev = @$m > 1 ? $m->[-2]{vend} + 1 : $open + 1;    # after the `,` (or the `{`)
        my $gap = substr($$t, $prev, $last->{kstart} - $prev);
        my $multi = $gap =~ /\n/ ? 1 : 0;
        my $ind = $multi ? _line_indent($t, $last->{kstart}) : undef;
        my $sep = substr($$t, $last->{kend}, $last->{vstart} - $last->{kend});
        my $val = _nest(\@rest, $leaf, $ind, $unit, $nl);
        substr($$t, $last->{vend}, 0) = ',' . ($multi ? "$nl$ind" : ' ') . _key_json($first) . $sep . $val;
        return;
    }
    my $ind = _line_indent($t, $open);
    my $in = $ind . $unit;
    my $val = _nest(\@rest, $leaf, $in, $unit, $nl);
    substr($$t, $open + 1, $close - $open - 1) = "$nl$in" . _key_json($first) . ": $val$nl$ind";
}

# edit(text, options key, [changes]) -> (new text) or (undef, why): each change {key, kind =>
# set|remove, json} done in order on the text the one before left.
sub edit {
    my ($text, $ckey, $changes) = @_;
    for my $c (@$changes) {
        my ($at, $why) = _find(\$text, $ckey);
        return (undef, $why) unless $at;
        if ($c->{kind} eq 'remove') {
            next unless defined $at->{opts};
            my ($m, $close) = _members(\$text, $at->{opts});
            my ($i) = grep { $m->[$_]{key} eq $c->{key} } 0 .. $#$m;
            next unless defined $i;
            my ($from, $to);
            if (@$m == 1) { ($from, $to) = ($at->{opts} + 1, $close) }
            elsif ($i < $#$m) { ($from, $to) = ($m->[$i]{kstart}, $m->[ $i + 1 ]{kstart}) }
            else { ($from, $to) = ($m->[ $i - 1 ]{vend}, $m->[$i]{vend}) }
            substr($text, $from, $to - $from) = '';
            next;
        }
        if (defined $at->{opts}) {
            my ($m) = _members(\$text, $at->{opts});
            my ($hit) = grep { $_->{key} eq $c->{key} } @$m;
            if ($hit) { substr($text, $hit->{vstart}, $hit->{vend} - $hit->{vstart}) = $c->{json}; next }
            _insert(\$text, $at->{opts}, [ $c->{key} ], $c->{json});
        }
        elsif (defined $at->{entry}) { _insert(\$text, $at->{entry}, [ 'options', $c->{key} ], $c->{json}) }
        elsif (defined $at->{pc}) { _insert(\$text, $at->{pc}, [ $ckey, 'options', $c->{key} ], $c->{json}) }
        else { _insert(\$text, $at->{root}, [ 'pluginConfigs', $ckey, 'options', $c->{key} ], $c->{json}) }
    }
    return ($text);
}

# expected(doc, options key, [changes]) -> the decoded settings with exactly those changes, the
# objects on the path copied (the rest shared with doc)
sub expected {
    my ($doc, $ckey, $changes) = @_;
    my %d = %$doc;
    my $pc = ref $d{pluginConfigs} eq 'HASH' ? { %{ $d{pluginConfigs} } } : {};
    my $en = ref $pc->{$ckey} eq 'HASH' ? { %{ $pc->{$ckey} } } : {};
    my $op = ref $en->{options} eq 'HASH' ? { %{ $en->{options} } } : {};
    for my $c (@$changes) {
        if ($c->{kind} eq 'remove') { delete $op->{ $c->{key} } } else { $op->{ $c->{key} } = $c->{data} }
    }
    $en->{options} = $op;
    $pc->{$ckey} = $en;
    $d{pluginConfigs} = $pc;
    return \%d;
}

# ---------------------------------------------------------------- values
sub consent { return $settings::FILE_ONLY{ $_[0] // '' } ? 1 : 0 }

sub window_floor {
    my $c = eval { spec::get('clamp') };
    my $v = ref $c eq 'HASH' ? $c->{window_floor} : undef;
    return (defined $v && !ref $v && $v =~ /\A[0-9]+\z/ && $v > 0) ? 0 + $v : 100000;
}

# _entry_bad(key, entry) -> why one entry of a list key is not read as written, else undef
sub _entry_bad {
    my ($key, $e) = @_;
    if ($key eq 'prod_patterns') { return settings::pattern_ok($e, $LIST_LEN) ? undef : 'not a pattern the plugin runs (at most 200 characters, compiling, no code or verb groups)' }
    if ($key eq 'secret_extra_rules') {
        my ($kind, $body) = $e =~ /\A(HARD|WARN|NAME):(.+)\z/s or return 'not HARD:<pattern>, WARN:<pattern> or NAME:<glob>';
        if ($kind eq 'NAME') { (my $g = $body) =~ s/\\x3b/;/gi; return ($g =~ m{/} || length($g) > $LIST_LEN) ? 'a NAME glob with a / or over 200 characters' : undef }
        return settings::pattern_ok($body, $LIST_LEN) ? undef : 'not a pattern the plugin runs (at most 200 characters, compiling, no code or verb groups)';
    }
    if ($key eq 'protected_branches') {
        (my $g = lc $e) =~ s{\Arefs/heads/}{};
        return settings::_branch_glob_ok($g) ? undef : 'not a branch name or glob the plugin takes';
    }
    if ($key eq 'deny_class_patterns') {
        $e =~ /\A\s*(?:sleep-poll|routing|secret|write-guard|scope|other)\s*=/ or return 'not <class>=<pattern> (class sleep-poll, routing, secret, write-guard, scope or other)';
        my $src = settings::trim(substr($e, $+[0]));
        return 'an empty pattern' if $src eq '';
        return (settings::pattern_ok($src, $LIST_LEN) && eval { qr/$src/i }) ? undef : 'not a pattern the plugin runs (at most 200 characters, compiling, no code or verb groups)';
    }
    if ($key eq 'relaunch_allow') { return ($e =~ /\A\^/ && settings::pattern_ok($e, $LIST_LEN)) ? undef : 'not a pattern starting ^ that the plugin runs' }
    # as settings::repo_roots reads an entry: a drive form is absolute under MSYS or Cygwin perl
    if ($key eq 'repo_roots') { return defined util::root_form($e) ? undef : 'not an absolute path' }
    return undef;    # driver_skills: names, any text
}

# check_value(key, text) -> ({unset => 1}) for an empty value (the default), ({data, json}) with the
# value as JSON (a number, true or false, or a string), or (undef, why). The rules are the
# plugin's readers' (settings.pm resolve and its list readers, the mod's config.ts), so a
# value that passes is read as written on its own: no min/max clamp, no fallback to the
# default. The cross-key clamp (a soft max or target over what the window or the soft max
# allows) depends on other keys and the model's window: clamp_notes says so, nothing refuses it.
sub check_value {
    my ($key, $in) = @_;
    my $t = util::text($in // '');
    return ({ unset => 1 }) if settings::trim($t) eq '';
    return (undef, 'it holds a control character') if $t =~ /[\x00-\x1f\x7f]/;
    return (undef, "it is longer than $VALUE_MAX bytes") if length(util::to_bytes($t)) > $VALUE_MAX;
    my $class = $settings::EXPORT{$key} // 'drop';
    my $str = sub { return ({ data => $_[0], json => jsonc::encode_bytes($_[0]) }) };
    if ($class eq 'bool') {
        my $x = lc settings::trim($t);
        return ({ data => jsonc::true(), json => 'true' }) if $x =~ /\A(?:true|yes|on|1)\z/;
        return ({ data => jsonc::false(), json => 'false' }) if $x =~ /\A(?:false|no|off|0)\z/;
        return (undef, 'not true or false');
    }
    if ($class eq 'num') {
        my $x = settings::trim($t);
        return (undef, 'not a number of 0 or more') unless $x =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
        my $n = 0 + $x;
        return (undef, 'too large') if $n >= $NUM_MAX;
        return (undef, 'not a whole number (the plugin rounds it down)') if $settings::WHOLE{$key} && $n != int($n);
        my ($lo, $hi) = settings::limits($key);
        return (undef, "below its minimum $lo") if defined $lo && $n < $lo;
        return (undef, "above its maximum $hi") if defined $hi && $n > $hi;
        my $floor = window_floor();
        return (undef, "0 (the window Claude Code reports) or at least $floor") if $key eq 'native_window_tokens' && $n > 0 && $n < $floor;
        # the JSON text must read back as the same number (Perl prints 1e+15 past 15 digits)
        return (undef, 'too many digits') unless "$n" =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
        return ({ data => $n, json => "$n" });
    }
    if ($class eq 'enum') {
        # a %SWITCH key takes true or false and its words from before 0.1.6, written as true or false
        my $x = exists $settings::SWITCH{$key} ? settings::switch_form($key, $t) // lc settings::trim($t) : lc settings::trim($t);
        my @v = @{ $settings::ENUM{$key} || [] };
        return grep({ $_ eq $x } @v) ? $str->($x) : (undef, 'not ' . join(', ', @v[0 .. $#v - 1]) . " or $v[-1]");
    }
    if ($class eq 'path') {
        return (undef, 'it starts or ends with a space') if $t ne settings::trim($t);
        return (undef, 'not an absolute path (/… or ~/…)') unless $t =~ m{\A(?:/|~/|~\z)};
        return $str->($t);
    }
    if ($class eq 'list') {
        my @e = settings::list($t);
        return (undef, "more than $LIST_MAX entries") if $key ne 'driver_skills' && @e > $LIST_MAX;
        for my $i (0 .. $#e) {
            my $bad = _entry_bad($key, $e[$i]) // next;
            return (undef, 'entry ' . ($i + 1) . ": $bad");
        }
        return $str->($t);
    }
    if ($key eq 'ticket_pattern') {
        return settings::pattern_ok($t, $LIST_LEN) ? $str->($t) : (undef, 'not a pattern the plugin runs (at most 200 characters, compiling, no code or verb groups)');
    }
    return $str->($t);
}

# same_as_default(key, data) -> 1 when the plugin reads the value as its default
sub same_as_default {
    my ($key, $data) = @_;
    my $d = settings::manifest_default($key);
    my $class = $settings::EXPORT{$key} // 'drop';
    return 1 if settings::_unset($d) && !ref $data && settings::trim($data) eq '';
    return 0 if !defined $d;
    if ($class eq 'bool') { return (settings::_coerce($key, $d) ? 1 : 0) == ($data ? 1 : 0) ? 1 : 0 }
    if ($class eq 'num') { return ("$d" =~ /\A-?[0-9]+(?:\.[0-9]+)?\z/ && 0 + $d == $data) ? 1 : 0 }
    if ($class eq 'enum') { return lc(settings::trim("$d")) eq $data ? 1 : 0 }
    if ($class eq 'path') {
        my $dp = defined &paths::named ? paths::named("$d") : "$d";
        return util::clean_path(util::to_bytes($dp)) eq util::clean_path(util::to_bytes($data)) ? 1 : 0;
    }
    if ($class eq 'list') { return join("\n", settings::list("$d")) eq join("\n", settings::list($data)) ? 1 : 0 }
    return "$d" eq $data ? 1 : 0;
}

# _saved_list(value) -> the entries of a saved list value (a JSON list of strings or numbers
# as its entries), else none
sub _saved_list {
    my ($v) = @_;
    return map { settings::trim("$_") } grep { defined && !ref } @$v if ref $v eq 'ARRAY';
    return () if ref $v;
    return settings::list($v);
}

# loosens(key, saved value, new data or undef for the default) -> why the change makes a
# protective key looser, else undef
sub loosens {
    my ($key, $saved, $new) = @_;
    if ($settings::NO_FLAG{$key}) {
        my %now = map { $_ => 1 } _saved_list(defined $new ? $new : '');
        my @gone = grep { !$now{$_} } _saved_list($saved);
        return @gone ? 'a protective list only gains entries here; ' . scalar(@gone) . ' of its saved entries would go' : undef;
    }
    if (my $order = $settings::TIGHTEN{$key}) {
        my %rank = map { $order->[$_] => $_ } 0 .. $#$order;
        # a %SWITCH key's values (true, false, a word from before 0.1.6) rank as the word they read as
        my $sw = exists $settings::SWITCH{$key};
        my $word = sub { my ($v) = @_; return $sw ? (settings::switch_read($key, $v))[0] : ref $v ? undef : lc settings::trim($v // '') };
        my $say = sub { return $sw ? settings::switch_form($key, $_[0]) : $_[0] };
        my $s = $word->($saved);
        return undef unless defined $s && exists $rank{$s};
        my $n = $word->(defined $new ? $new : settings::manifest_default($key) // $order->[0]);
        return (defined $n && exists $rank{$n} && $rank{$n} < $rank{$s}) ? 'it only goes towards ' . $say->($order->[-1]) . ' here (saved ' . $say->($s) . ')' : undef;
    }
    return undef;
}

# old_form(key, saved value) -> 1 for a saved value of an enum key that is not one of its %ENUM
# values as written (a word from before 0.1.6, another case, a JSON true or false)
sub old_form {
    my ($key, $v) = @_;
    my $e = $settings::ENUM{$key} or return 0;
    return 0 if !defined $v || (!ref $v && grep { $_ eq $v } @$e);
    return (!ref $v || ref $v eq 'jsonc::Bool') ? 1 : 0;
}

# shown(key, value or undef) -> the value as /status prints it (never a pattern's or a list's text)
sub shown {
    my ($key, $v) = @_;
    return 'saved empty' if defined $v && !ref $v && $v eq '';
    $v = join ';', map { "$_" } @$v if ref $v eq 'ARRAY';
    return settings::show_value($key, $v);
}

# _clamp_flags(values, spec) -> {key => 1} for the numbers the clamp lowers with these values:
# the watcher's flags (watch::export::clamped_keys: min/max, the window floor, the soft max and
# target over the configured window's clamp), and a target over what its soft max allows
# (target_num/target_den of it), which holds for any window, the model's too.
sub _clamp_flags {
    my ($r, $vals, $spec) = @_;
    my $cl = eval { require watch::export; watch::export::clamped_keys({ %$r, values => $vals }, $spec) };
    my %c = ref $cl eq 'HASH' ? %$cl : ();
    my $K = eval { require watch::rules; watch::rules::clamp_constants($spec) };
    my ($soft, $target) = map { settings::_coerce($_, $vals->{$_}) } qw(compact_soft_max_tokens compact_target_tokens);
    if (ref $K eq 'HASH' && defined $soft && defined $target && lc($vals->{triggers} // 'true') !~ /\A(?:0|false)\z/) {
        my $q = ($soft * $K->{target_num}) / $K->{target_den};
        $c{compact_target_tokens} = 1 if $target > $q;
    }
    return \%c;
}

# clamp_notes(plan) -> a note per number the clamp lowers once the plan's changes are in place
# and did not before, or that the plan changes (set: written as given; removed: put back to its
# default): the value is still written so (the plugin reads it so, and its clamp works the
# threshold out), never refused here.
sub clamp_notes {
    my ($p) = @_;
    my $r = eval { settings::resolve({}) };
    return () unless ref $r eq 'HASH' && ref $r->{values} eq 'HASH';
    my $spec = eval { spec::load() };
    my %after = %{ $r->{values} };
    my %changed;
    for my $c (@{ $p->{changes} || [] }) {
        my $raw = $c->{kind} eq 'remove' ? $r->{defaults}{ $c->{key} } : $c->{data};
        my $x = defined $raw ? settings::_coerce($c->{key}, $raw) : undef;
        $after{ $c->{key} } = $x if defined $x;
        $changed{ $c->{key} } = $c->{kind};
    }
    my $before = _clamp_flags($r, $r->{values}, $spec);
    my $now = _clamp_flags($r, \%after, $spec);
    my @k = grep { $now->{$_} && ($changed{$_} || !$before->{$_}) && ($settings::EXPORT{$_} // '') eq 'num' } map { $_->[0] } @settings::KEYS;
    return map { "  note: $_: " . (!$changed{$_} ? 'not changed' : $changed{$_} eq 'remove' ? 'put back to its default' : 'written as given') . ", but with these settings the plugin's clamp lowers it (the target to at most two thirds of the soft max, both below what the window allows); /"
                 . ctx::brand() . ':status shows the value it uses' } @k;
}

# ---------------------------------------------------------------- the plugin's key
# plugin_key(pluginConfigs hash or undef, settings doc or undef) -> (key, how) or (undef, why):
# the key in use (settings::options_key; an @inline run gives undef, inline), else
# `<plugin>@<marketplace>` from the installed copy's folder
# (<config dir>/plugins/cache/<marketplace>/<plugin>/<version>/, or the marketplace whose folder
# holds it, settings::load_source), else the one enabledPlugins
# key for the plugin.
sub plugin_key {
    my ($pc, $doc) = @_;
    return (undef, 'inline') if defined settings::inline_key();
    my ($k, $cand) = settings::options_key($pc);
    return ($k, 'found') if defined $k;
    return (undef, 'ambiguous') if @$cand > 1;
    my $brand = ctx::brand();
    my $root = Cwd::abs_path(ctx::root() // '') // '';
    my $cache = Cwd::abs_path(settings::config_dir() . '/plugins/cache');
    if (defined $cache && $root =~ m{\A\Q$cache\E/([^/]+)/\Q$brand\E(?:/|\z)}) { return ("$brand\@$1", 'installed') }
    # 0.1.9: read in place from a marketplace's folder (a directory marketplace)
    my $ld = settings::load_source(ctx::root());
    return ("$brand\@$ld->{mkt}", 'installed') if $ld->{kind} eq 'marketplace';
    my $en = ref $doc eq 'HASH' && ref $doc->{enabledPlugins} eq 'HASH' ? $doc->{enabledPlugins} : {};
    my @e = grep { (split /\@/, $_, 2)[0] eq $brand && /\@./ } sort keys %$en;
    return ($e[0], 'enabled') if @e == 1;
    return (undef, 'no-key');
}

# _sq(text) -> the text as one single-quoted shell word
sub _sq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'" }

# consent_lines(refusal, plugin key or undef) -> the lines that tell the user how to change a
# consent key themselves (the plugin never writes these keys): /config or the file by hand, and
# for a valid new value Claude Code's own `plugin configure`, a line the user types.
sub consent_lines {
    my ($r, $pk) = @_;
    my $brand = ctx::brand();
    my $key = $r->{key};
    my @l = ("  $key: a consent key; the plugin never writes it, whoever runs this. Change it yourself in /config (the row $brand.$key)"
             . ' or in your settings.json by hand');
    push @l, "  $key: the value given: $r->{detail}" if defined $r->{detail};
    if (defined $r->{value}) {
        my $json = jsonc::encode_bytes(jsonc::obj($key => $r->{value}));
        push @l, "  $key: or type: ! printf '%s' " . _sq($json) . ' | claude plugin configure ' . _sq($pk // "$brand\@<marketplace>") . ' --values-stdin';
    }
    return @l;
}

# ---------------------------------------------------------------- plan and apply
sub _sha12 { return substr(sha::hex256($_[0]), 0, 12) }

sub _real { my ($f) = @_; return Cwd::abs_path(util::fsb($f)) // $f }

# _links(file) -> the link count of the file's real path (0 when it cannot be read)
sub _links { my @st = stat _real($_[0]); return @st ? $st[3] : 0 }

# plan(\@requests) -> {state => refused|nothing|ok, refusals => [{key?, why, text, lines}], file,
#   raw, sha, ckey, doc, options, changes => [{key, kind => set|remove, json, data, old, new}],
#   same => [{key, why => unchanged|not-saved}]}. A request is {key, kind => set, text} or {key,
#   kind => remove}. Every request is checked; any refusal refuses the whole plan.
sub plan {
    my ($reqs) = @_;
    my $file = settings::config_dir() . '/settings.json';
    my %p = (file => $file, refusals => [], changes => [], same => []);
    my $refuse = sub { push @{ $p{refusals} }, {@_}; return };
    # the consent keys first, on every path: nothing about the file decides it
    for my $r (grep { consent($_->{key}) } @$reqs) {
        my ($v, $why) = $r->{kind} eq 'set' ? check_value($r->{key}, $r->{text}) : ();
        $refuse->(key => $r->{key}, why => 'consent', ($v && !$v->{unset} ? (value => $v->{data}) : ()), detail => $why);
    }
    my %val;
    for my $r (grep { !consent($_->{key}) && $_->{kind} eq 'set' } @$reqs) {
        my ($v, $why) = check_value($r->{key}, $r->{text});
        if (!$v) { $refuse->(key => $r->{key}, why => 'invalid', detail => $why); next }
        $val{ $r->{key} } = $v;
    }
    my $raw = util::read_file($file);
    my $doc = defined $raw ? eval { jsonc::decode($raw) } : undef;
    my $pc = ref $doc eq 'HASH' && ref $doc->{pluginConfigs} eq 'HASH' ? $doc->{pluginConfigs} : undef;
    my ($ckey, $how) = plugin_key($pc, $doc);
    $p{ckey} = $ckey;
    $p{ckey_how} = $how;
    if (@{ $p{refusals} }) { $p{state} = 'refused'; return \%p }
    my $wr = settings::write_refused();
    # a file that is not plain JSON at all (comments, a trailing comma) says so
    $wr = 'not-json' if defined $wr && $wr eq 'unparseable' && defined $raw && ref $doc ne 'HASH';
    return { %p, state => 'refused', refusals => [{ why => $wr }] } if defined $wr;
    # only removals and no saved options (no file, no entry for the plugin): nothing to do
    my $none_saved = !defined $raw || (ref $doc eq 'HASH' && !(ref $pc eq 'HASH' && defined $ckey && ref $pc->{$ckey} eq 'HASH'));
    if ($none_saved && !grep { $_->{kind} eq 'set' } @$reqs) {
        my %seen;
        return { %p, raw => $raw, state => 'nothing', same => [ map { { key => $_->{key}, why => 'not-saved' } } grep { !$seen{ $_->{key} }++ } @$reqs ] };
    }
    return { %p, state => 'refused', refusals => [{ why => 'no-file' }] } unless defined $raw;
    $p{raw} = $raw;
    $p{sha} = _sha12($raw);
    return { %p, state => 'refused', refusals => [{ why => 'not-json' }] } unless ref $doc eq 'HASH';
    return { %p, state => 'refused', refusals => [{ why => $how }] } unless defined $ckey;
    my ($at, $why) = _find(\$raw, $ckey);
    return { %p, state => 'refused', refusals => [{ why => $why }] } unless $at;
    $p{doc} = $doc;
    my $opts = defined $pc && ref $pc->{$ckey} eq 'HASH' && ref $pc->{$ckey}{options} eq 'HASH' ? $pc->{$ckey}{options} : {};
    $p{options} = $opts;
    my %seen;
    for my $r (@$reqs) {
        my $k = $r->{key};
        next if $seen{$k}++;
        my $v = $val{$k};
        my $saved = exists $opts->{$k};
        my $to_default = $r->{kind} eq 'remove' || $v->{unset} || same_as_default($k, $v->{data});
        if (my $l = loosens($k, $saved ? $opts->{$k} : undef, $to_default ? undef : $v->{data})) {
            $refuse->(key => $k, why => 'loosen', detail => $l);
            next;
        }
        if ($to_default) {
            if (!$saved) { push @{ $p{same} }, { key => $k, why => 'not-saved' }; next }
            push @{ $p{changes} }, { key => $k, kind => 'remove', old => shown($k, $opts->{$k}), raw => $opts->{$k},
                                     new => 'default ' . settings::show_value($k, settings::manifest_default($k)) };
            next;
        }
        if ($saved && jsonc::encode($opts->{$k}) eq jsonc::encode($v->{data})) { push @{ $p{same} }, { key => $k, why => 'unchanged' }; next }
        push @{ $p{changes} }, { key => $k, kind => 'set', json => $v->{json}, data => $v->{data}, ($saved ? (raw => $opts->{$k}) : ()),
                                 old => $saved ? shown($k, $opts->{$k}) : 'default ' . settings::show_value($k, settings::manifest_default($k)),
                                 new => shown($k, $v->{data}) };
    }
    if (@{ $p{refusals} }) { $p{state} = 'refused'; return \%p }
    return { %p, state => 'nothing' } unless @{ $p{changes} };
    return { %p, state => 'refused', refusals => [{ why => 'hard-link' }] } if _links($file) > 1;
    return { %p, state => 'ok' };
}

# _put(new path, bytes, mode, seam name, then) -> 1 when the file was created and written, 0 when
# the name is taken; else dies after removing what it created, so no partial file is left. The
# file is created 0600 (O_EXCL), written in full, synced and closed, then given its mode and
# handed to `then` (the rename for the settings file). Test seam STORE_TEST_SETTINGS_FAIL=<seam
# name> stops the write at half, as on a full disk.
sub _put {
    my ($path, $data, $mode, $seam, $then) = @_;
    my $fh;
    if (!sysopen($fh, $path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600)) {
        return 0 if $!{EEXIST};
        die "create: $!\n";
    }
    my $ok = eval {
        my $half = (util::test_mode() && ($ENV{STORE_TEST_SETTINGS_FAIL} // '') eq $seam) ? int(length($data) / 2) : undef;
        my $out = defined $half ? substr($data, 0, $half) : $data;
        my $off = 0;
        while ($off < length $out) {
            my $n = syswrite($fh, $out, length($out) - $off, $off);
            die "write: $!\n" unless defined $n;
            $off += $n;
        }
        die "write: no space left on device (test)\n" if defined $half;
        eval { require IO::Handle; $fh->sync };
        close($fh) or die "close: $!\n";
        chmod($mode, $path) or die "chmod: $!\n";
        $then->() if $then;
        1;
    };
    if (!$ok) {
        my $e = $@ || "write failed\n";
        close $fh if defined fileno($fh);
        unlink $path;
        die $e;
    }
    return 1;
}

# _write(real path, bytes, mode): a temp file in the same folder, then a rename; any failure
# removes the temp file and dies, so the file keeps its old bytes and no partial file is left.
sub _write {
    my ($real, $data, $mode) = @_;
    my $tmp = sprintf('%s.%s-tmp-%d-%04x', $real, ctx::brand(), $$, int(rand(65536)));
    _put($tmp, $data, $mode, 'write', sub { rename($tmp, $real) or die "rename: $!\n" }) or die "create a temp file: it exists\n";
    return 1;
}

# backup_path(stamp, n) -> the backup's name next to the settings file
sub backup_path {
    my ($stamp, $n) = @_;
    return settings::config_dir() . '/settings.json.' . ctx::brand() . "-$stamp" . ($n > 1 ? "-$n" : '') . '.bak';
}

# apply(plan) -> {state => done|refused, why, backup, error}
sub apply {
    my ($p) = @_;
    my ($new, $why) = edit($p->{raw}, $p->{ckey}, $p->{changes});
    return { state => 'refused', why => $why } unless defined $new;
    my $got = eval { jsonc::decode($new) };
    return { state => 'refused', why => 'verify' }
        unless ref $got eq 'HASH' && jsonc::encode($got) eq jsonc::encode(expected($p->{doc}, $p->{ckey}, $p->{changes}));
    my $real = _real($p->{file});
    my @st = stat $real;
    return { state => 'refused', why => 'not-file' } unless @st && -f _;
    # a hard-linked settings.json: the rename puts a new file under this name only, so the other
    # name would keep the old text
    return { state => 'refused', why => 'hard-link' } if $st[3] > 1;
    my $mode = $st[2] & 07777;
    my $before = util::read_file($real);
    return { state => 'refused', why => 'changed-now' } unless defined $before && $before eq $p->{raw};
    my $stamp = util::file_stamp();
    my ($backup, $berr);
    for my $n (1 .. 99) {
        my $b = backup_path($stamp, $n);
        # a backup that fails partway is removed by _put: no partial .bak is left
        my $made = eval { _put($b, $p->{raw}, 0600, 'backup') };
        if ($made) { $backup = $b; last }
        if (!defined $made) { $berr = $@ =~ s/\n.*//sr; last }
    }
    return { state => 'refused', why => 'backup', (defined $berr ? (error => $berr) : ()) } unless defined $backup;
    if (util::test_mode() && defined $ENV{STORE_TEST_SETTINGS_RACE}) {
        open(my $fh, '>:raw', $real) or die "race seam: $!\n";
        print $fh $ENV{STORE_TEST_SETTINGS_RACE};
        close $fh;
    }
    # compare right before the rename: Claude Code writes this file too (/config, a plugin install)
    my $now = util::read_file($real);
    return { state => 'refused', why => 'changed-now', backup => $backup } unless defined $now && $now eq $p->{raw};
    my $ok = eval { _write($real, $new, $mode); 1 };
    return { state => 'refused', why => 'write', error => ($@ =~ s/\n.*//sr), backup => $backup } unless $ok;
    my $after = util::read_file($real);
    return { state => 'refused', why => 'after', backup => $backup } unless defined $after && $after eq $new;
    return { state => 'done', backup => $backup };
}

1;

package settings_reset;
# lib/settings_reset.pm: `settings reset` (0.1.2 visible defaults, spec Behaviour 4). Owner: WP-core.
# plan(keys | 'all', given plan) -> what a reset of the plugin's saved options would remove from
# ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json; apply(plan, watch) does it. The options key is
# found by settings::options_key, the rule the settings are read with; an ambiguous key, a file
# that is not plain JSON (comments, a trailing comma) and a file that names a member on the
# path twice are refused, and so is a hard-linked file (the write would split its names). --all leaves %settings::RESET_KEEP (the consent and protective keys
# and resume_proceed; OPEN-2, the spec's recommendation) and keys the plugin does not know.
# The write is a text splice of exactly those members: jsonc::decode returns unordered hashes
# and encode_pretty sorts keys, so a re-encode would reorder the user's whole file. Before it
# writes: a backup of the whole file in the plugin's own store (<watch>/settings-backups/
# <stamp>.json, 0600), a check that the new text decodes to the old settings minus those
# members, and a re-read that refuses a file changed since the plan; then an atomic write to
# the file's real path (a symlinked settings.json keeps its link) with its mode. An emptied
# options object stays {}.
use strict;
use warnings;
use utf8;
require Cwd;

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

# _members(text ref, pos of `{`) -> ([{key, kstart, vend}], close offset)
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
        push @m, { key => $key, kstart => $ks, vstart => $vs, vend => $ve };
        $p = _ws($t, $ve);
        my $d = substr($$t, $p, 1);
        return (\@m, $p) if $d eq '}';
        $p = _ws($t, $p + 1);
    }
}

# _options_object(text ref, options key) -> ({open, close, members}) or (undef, why). Refuses a
# member named twice on the path or in the options object.
sub _options_object {
    my ($t, $ckey) = @_;
    my $p = _ws($t, 0);
    for my $name ('pluginConfigs', $ckey, 'options') {
        return (undef, 'not-object') unless substr($$t, $p, 1) eq '{';
        my ($m) = _members($t, $p);
        my @hit = grep { $_->{key} eq $name } @$m;
        return (undef, "twice:$name") if @hit > 1;
        return (undef, 'missing') unless @hit;
        $p = $hit[0]{vstart};
    }
    return (undef, 'not-object') unless substr($$t, $p, 1) eq '{';
    my ($m, $close) = _members($t, $p);
    my %n;
    for (@$m) { return (undef, "twice:$_->{key}") if $n{ $_->{key} }++ }
    return ({ open => $p, close => $close, members => $m });
}

# splice_out(text, options key, [member names]) -> (new text) or (undef, why): each member
# removed with the separator on one side, so the members around it keep their bytes.
sub splice_out {
    my ($text, $ckey, $names) = @_;
    for my $name (@$names) {
        my ($ob, $why) = _options_object(\$text, $ckey);
        return (undef, $why) unless $ob;
        my $m = $ob->{members};
        my ($i) = grep { $m->[$_]{key} eq $name } 0 .. $#$m;
        next unless defined $i;
        my ($from, $to);
        if (@$m == 1) { ($from, $to) = ($ob->{open} + 1, $ob->{close}) }
        elsif ($i < $#$m) { ($from, $to) = ($m->[$i]{kstart}, $m->[ $i + 1 ]{kstart}) }
        else { ($from, $to) = ($m->[ $i - 1 ]{vend}, $m->[$i]{vend}) }
        substr($text, $from, $to - $from) = '';
    }
    return ($text);
}

# ---------------------------------------------------------------- plan and apply
sub _sha12 { return substr(sha::hex256($_[0]), 0, 12) }

# _links(file) -> the link count of the file's real path (0 when it cannot be read)
sub _links {
    my ($file) = @_;
    my $real = Cwd::abs_path(util::fsb($file)) // $file;
    my @st = stat $real;
    return @st ? $st[3] : 0;
}

# plan(\@keys | 'all') -> {state => refused|nothing|ok, why, file, raw, sha, ckey, remove => [..],
#   not_saved => [..], kept => [..], options => {..}}; keys in @KEYS order.
sub plan {
    my ($want) = @_;
    my $file = settings::config_dir() . '/settings.json';
    my %p = (file => $file, remove => [], not_saved => [], kept => []);
    my $raw = util::read_file($file);
    return { %p, state => 'nothing', why => 'no-file' } unless defined $raw;
    $p{raw} = $raw;
    $p{sha} = _sha12($raw);
    my $doc = eval { jsonc::decode($raw) };
    return { %p, state => 'refused', why => 'not-json' } unless ref $doc eq 'HASH';
    my $pc = $doc->{pluginConfigs};
    return { %p, state => 'nothing', why => 'no-options' } unless ref $pc eq 'HASH';
    my ($ckey, $cand) = settings::options_key($pc);
    return { %p, state => 'refused', why => 'ambiguous', candidates => $cand } if !defined $ckey && @$cand > 1;
    my $opts = defined $ckey && ref $pc->{$ckey} eq 'HASH' ? $pc->{$ckey}{options} : undef;
    return { %p, state => 'nothing', why => 'no-options' } unless ref $opts eq 'HASH';
    $p{ckey} = $ckey;
    $p{doc} = $doc;
    $p{options} = $opts;
    my %named = $want eq 'all' ? () : map { $_ => 1 } @$want;
    for my $k (map { $_->[0] } @settings::KEYS) {
        if ($want eq 'all') {
            next unless exists $opts->{$k};
            if ($settings::RESET_KEEP{$k}) { push @{ $p{kept} }, $k; next }
            push @{ $p{remove} }, $k;
        } elsif ($named{$k}) {
            push @{ exists $opts->{$k} ? $p{remove} : $p{not_saved} }, $k;
        }
    }
    # a member named twice (the decoded file keeps only the last) is refused before any plan
    my ($ob, $why) = _options_object(\$raw, $ckey);
    return { %p, state => 'refused', why => $why } if !$ob && $why =~ /\Atwice:/;
    return { %p, state => 'refused', why => 'hard-link' } if @{ $p{remove} } && _links($file) > 1;
    return { %p, state => (@{ $p{remove} } ? 'ok' : 'nothing'), why => (@{ $p{remove} } ? undef : 'none-saved') };
}

# now_text(plan, key) -> the saved value as status shows it (never a pattern's or a list's text)
sub now_text {
    my ($p, $k) = @_;
    my $v = $p->{options}{$k};
    return 'saved empty' if defined $v && !ref $v && $v eq '';
    return settings::show_value($k, $v);
}

# notes(plan) -> what the default of each consent or protective key being removed does
sub notes {
    my ($p) = @_;
    my @l;
    for my $k (grep { $settings::RESET_KEEP{$_} } @{ $p->{remove} }) {
        my $e = $settings::RESET_EFFECT{$k} // next;
        # `(looser than now)` only while the saved value differs from the default
        $e =~ s/ \(looser than now\)\z// if now_text($p, $k) eq settings::show_value($k, settings::manifest_default($k));
        push @l, "  note: $k: $e";
    }
    return @l;
}

# apply(plan, watch dir) -> {state => done|refused, why, backup}
sub apply {
    my ($p, $watch) = @_;
    my ($new, $why) = splice_out($p->{raw}, $p->{ckey}, $p->{remove});
    return { state => 'refused', why => "splice:$why" } unless defined $new;
    # the result must be the old settings minus exactly those members
    my $got = eval { jsonc::decode($new) };
    my %want = %{ $p->{doc} };
    my $pc = { %{ $want{pluginConfigs} } };
    my $obj = { %{ $pc->{ $p->{ckey} } } };
    my $opts = { %{ $obj->{options} } };
    delete @$opts{ @{ $p->{remove} } };
    $obj->{options} = $opts;
    $pc->{ $p->{ckey} } = $obj;
    $want{pluginConfigs} = $pc;
    return { state => 'refused', why => 'verify' } unless ref $got eq 'HASH' && jsonc::encode($got) eq jsonc::encode(\%want);
    return { state => 'refused', why => 'no-watch' } unless defined $watch && $watch ne '';
    my $real = Cwd::abs_path(util::fsb($p->{file})) // $p->{file};
    my @st = stat $real;
    return { state => 'refused', why => 'not-file' } unless @st && -f _;
    # a hard-linked settings.json (a CLAUDE_CONFIG_DIR's link to ~/.claude/settings.json): the
    # atomic write puts a new file under this name only, so the other name would keep the old text
    return { state => 'refused', why => 'hard-link' } if $st[3] > 1;
    my $mode = $st[2] & 07777;
    my $before = util::read_file($real);
    return { state => 'refused', why => 'changed' } unless defined $before && $before eq $p->{raw};
    my $dir = "$watch/settings-backups";
    my $stamp = util::file_stamp();
    my $backup;
    for my $n (1 .. 99) {
        my $b = "$dir/$stamp" . ($n > 1 ? "-$n" : '') . '.json';
        if (util::write_excl($b, $p->{raw}, 0600)) { $backup = $b; last }
    }
    return { state => 'refused', why => 'backup' } unless defined $backup;
    # compare before the rename: the file may have changed since it was read (Claude Code writes it too)
    my $now = util::read_file($real);
    return { state => 'refused', why => 'changed', backup => $backup } unless defined $now && $now eq $p->{raw};
    util::write_atomic($real, $new, $mode);
    return { state => 'done', backup => $backup };
}

1;

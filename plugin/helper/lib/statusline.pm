package statusline;
# lib/statusline.pm: `settings statusline show [--json] [--sid <id>]` (0.1.13), read-only.
# Which status line Claude Code runs and the meter's snippet for that case: the `statusLine` of the
# user (${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json), project (<project>/.claude/settings.json)
# and local (<project>/.claude/settings.local.json) scopes, local over project over user; the
# project folder is CLAUDE_PROJECT_DIR when that is an absolute path, else the working folder.
# Managed settings are not read (a note says so). The command is classified (none, plain,
# ccstatusline, other, ours) and named by one basename only: never the full command or any other
# value, which can hold a secret. Then the meter in UTF-8 and ASCII (live for --sid, and fixed
# samples, lib/cachestate.pm bar()) and the snippet the user pastes: this writes no file.
use strict;
use warnings;
use utf8;

our $MAX_BYTES = 1024 * 1024;
our @ORDER = qw(user project local);
our %FILE_TEXT = (user => undef, project => '.claude/settings.json', local => '.claude/settings.local.json');
# a first word that runs a package by name (a status line tool of someone else's)
our %RUNNER = map { $_ => 1 } qw(npx bunx pnpx pnpm yarn uvx pipx dlx);
# a first word that runs the next one (the script or package named is the useful basename)
our %INTERP = map { $_ => 1 } qw(sh bash zsh dash ksh env node bun deno python python3 perl ruby npx bunx pnpx pnpm yarn uvx pipx dlx exec);

sub schema { return ctx::brand() . '-statusline/v1' }

sub project_dir {
    my $p = $ENV{CLAUDE_PROJECT_DIR};
    return $p if defined $p && $p =~ m{\A/};
    require Cwd;
    return Cwd::getcwd();
}

# files() -> [{scope, path}] in @ORDER
sub files {
    my $proj = project_dir();
    my @f = ({ scope => 'user', path => settings::config_dir() . '/settings.json' });
    push @f, { scope => 'project', path => "$proj/.claude/settings.json" }, { scope => 'local', path => "$proj/.claude/settings.local.json" }
        if defined $proj && $proj =~ m{\A/};
    return \@f;
}

# read_scope(path) -> {exists, readable, set, value}: `set` when the file is a JSON object with a
# statusLine key that is not null
sub read_scope {
    my ($path) = @_;
    my %r = (exists => (-e $path ? 1 : 0), readable => 0, set => 0, value => undef);
    return \%r unless -f $path;
    my $raw = util::read_file($path, $MAX_BYTES + 1);
    return \%r unless defined $raw && length($raw) <= $MAX_BYTES;
    my $j = eval { jsonc::decode($raw) };
    return \%r unless ref $j eq 'HASH';
    $r{readable} = 1;
    if (exists $j->{statusLine} && defined $j->{statusLine}) { @r{qw(set value)} = (1, $j->{statusLine}) }
    return \%r;
}

# _words(command) -> its words, with '…' and "…" quoting and backslashes read as sh does (enough
# to find the first words; nothing here is run)
sub _words {
    my ($c) = @_;
    my (@w, $cur, $q);
    for my $ch (split //, $c) {
        if (defined $q) {
            if ($ch eq $q) { undef $q } else { $cur .= $ch }
            next;
        }
        if ($ch eq "'" || $ch eq '"') { $q = $ch; $cur //= ''; next }
        if ($ch =~ /[\s;|&]/) {
            push @w, $cur if defined $cur;
            undef $cur;
            last if $ch =~ /[;|&]/;
            next;
        }
        $cur .= $ch;
    }
    push @w, $cur if defined $cur;
    return @w;
}

# name(command) -> the basename of what it runs (env assignments and flags skipped; through one
# interpreter or package runner), printable characters only, at most 40; or undef
sub name {
    my ($c) = @_;
    return undef unless defined $c && !ref $c;
    my @w = grep { !/\A[A-Za-z_][A-Za-z0-9_]*=/ } _words($c);
    my $first = shift @w // return undef;
    my $n = util::basename($first);
    if ($INTERP{$n}) {
        my ($next) = grep { !/\A-/ && $_ ne 'run' && $_ ne 'dlx' && $_ ne 'exec' } @w;
        $n = util::basename($next) if defined $next && $next ne '';
    }
    $n =~ s/[^A-Za-z0-9._@+-]//g;
    $n = substr($n, 0, 40);
    return $n eq '' ? undef : $n;
}

# classify(statusLine value) -> none, ours, ccstatusline, other or plain
sub classify {
    my ($v) = @_;
    return 'none' unless defined $v;
    return 'other' unless ref $v eq 'HASH' && ($v->{type} // '') eq 'command' && defined $v->{command} && !ref $v->{command} && $v->{command} =~ /\S/;
    my $c = $v->{command};
    my $launcher = quotemeta(util::basename(ctx::launcher()));
    return 'ours' if $c =~ /$launcher['"]?\s+cache\b/;
    return 'ccstatusline' if $c =~ /ccstatusline/i;
    my @w = grep { !/\A[A-Za-z_][A-Za-z0-9_]*=/ } _words($c);
    return 'other' if @w && $RUNNER{ util::basename($w[0]) };
    return 'plain';
}

# the meter's command, the shim as one quoted sh word
sub command { return 'sh ' . cachestate::_sh_word(cachestate::shim_path() // '~/.local/state/' . ctx::brand() . '/bin/' . ctx::brand() . '-store') . ' cache --stdin --bar --note-usage' }

# samples() -> [[name, report]...]: fixed reports for the preview (now 0, the one-hour tier)
sub samples {
    my $w = sub { my ($left, %x) = @_; return { state => 'warm', why => undef, ttl => '1h', source => 'claude-code', now => 0, expires_at => $left, seconds_left => $left, keep_warm => undef, %x } };
    my $kw = { active => 1, n => 3, max => 7, pending => 0, off => undef };
    return [
        ['warm', $w->(3000)],
        ['warm, half the hour gone', $w->(1500)],
        ['warm, nearly cold', $w->(200)],
        ['keep-warm, ping 3 of 7', $w->(3300, keep_warm => $kw)],
        ['keep-warm, a ping pending', $w->(3300, keep_warm => { %$kw, pending => 1 })],
        ['keep-warm off near a usage limit', $w->(1800, keep_warm => { active => 0, n => 0, max => 7, pending => 0, off => 'near-limit' })],
        ['TTL read from the transcript', $w->(2700, source => 'transcript')],
        ['cold', { state => 'cold', why => 'expired', ttl => '1h', source => 'claude-code', now => 0, expires_at => -120, seconds_left => 0 }],
        ['keep-warm ping missed', { state => 'cold', why => 'fork-miss', ttl => '1h', source => 'claude-code', now => 0 }],
        ['compacted', { state => 'cold', why => 'compacted', ttl => '1h', source => 'claude-code', now => 0 }],
    ];
}

# view(sid) -> the whole reading, as `--json` prints it
sub view {
    my ($sid) = @_;
    my (@scopes, $win);
    for my $f (@{ files() }) {
        my $s = read_scope($f->{path});
        my $cls = $s->{set} ? classify($s->{value}) : 'none';
        my $nm = $s->{set} && ref $s->{value} eq 'HASH' ? name($s->{value}{command}) : undef;
        my $row = { scope => $f->{scope}, file => util::abbrev($f->{path}), exists => jsonc::bool($s->{exists}),
                    readable => jsonc::bool($s->{readable}), set => jsonc::bool($s->{set}), class => $cls, name => $nm,
                    has_bar => jsonc::bool($cls eq 'ours' && $s->{value}{command} =~ /\s--bar\b/) };
        push @scopes, $row;
        $win = $row if $s->{set};
    }
    my $shim = cachestate::shim_path();
    my ($live, $why);
    if (defined $sid && $sid ne '') {
        my $r = eval { cachestate::report(sid => $sid) };
        $live = $r ? { utf8 => cachestate::bar($r), ascii => cachestate::bar($r, ascii => 1), state => $r->{state}, why => $r->{why}, ttl => $r->{ttl} } : undef;
    }
    my @samples = map { { name => $_->[0], utf8 => cachestate::bar($_->[1]), ascii => cachestate::bar($_->[1], ascii => 1) } } @{ samples() };
    my $cls = $win ? $win->{class} : 'none';
    my $scope = $win ? $win->{scope} : 'user';
    return {
        schema => schema(),
        scopes => \@scopes,
        winner => ($win ? $win->{scope} : undef),
        class => $cls,
        name => ($win ? $win->{name} : undef),
        has_bar => ($win ? $win->{has_bar} : jsonc::false()),
        managed => 'not-read',
        shim => { path => (defined $shim ? util::abbrev($shim) : undef), exists => jsonc::bool(defined $shim && -f $shim) },
        command => command(),
        live => $live,
        samples => \@samples,
        snippet => snippet($cls, $scope, $win),
    };
}

sub _target { my ($scope) = @_; return $scope eq 'user' ? util::abbrev(settings::config_dir() . '/settings.json') : $FILE_TEXT{$scope} . ' in the project folder' }

# snippet(class, scope, winner row) -> {case, target, lines}
sub snippet {
    my ($cls, $scope, $win) = @_;
    my $cmd = command();
    my $t = _target($scope);
    my $json = '"statusLine": {"type": "command", "command": ' . jsonc::encode_bytes($cmd) . ', "refreshInterval": 30}';
    my @script = ('#!/bin/sh', 'in=$(head -c 1048576)', q{printf '%s' "$in" | <your current command>},
                  't=' . cachestate::_sh_word(cachestate::shim_path() // '') . q{; [ -x "$t" ] && printf '%s' "$in" | "$t" cache --stdin --bar --note-usage 2>/dev/null}, 'exit 0');
    my $wrap = 'or keep your line and add the meter as a second line: save this script, make it executable, put your current command where it says, and point statusLine\'s command at the script';
    if ($cls eq 'ours') {
        return { case => 'ours', target => $t, lines => [$win && $win->{has_bar} ? 'already set: nothing to change'
            : 'already set, as the plain line: add --bar to the command in ' . $t . ' for the meter'] };
    }
    if ($cls eq 'none') {
        return { case => 'none', target => $t, lines => ["add at the top level of $t (inside its outer { }, with a comma after the entry before it):", $json] };
    }
    if ($cls eq 'ccstatusline') {
        return { case => 'ccstatusline', target => $t, lines => [
            'add a Custom Command widget in ccstatusline\'s own settings screen (its config file is left as it is):',
            "  command: $cmd", '  timeout: 1000', '  preserve colors: on (or add --color never to the command and leave it off)',
            $wrap . ':', @script ] };
    }
    if ($cls eq 'other') {
        return { case => 'other', target => $t, lines => [
            'add this command where your status line tool takes a command of your own (a custom command widget):', "  $cmd",
            $wrap . ':', @script ] };
    }
    return { case => 'plain', target => $t, lines => [
        "your status line runs a command of your own (set in $t). Claude Code runs one command, so replacing it drops your line;",
        "to replace it, set statusLine in $t to:", $json, $wrap . ':', @script ] };
}

# show_lines(view) -> the text form
sub show_lines {
    my ($v) = @_;
    my @out;
    for my $s (@{ $v->{scopes} }) {
        my $what = !$s->{exists} ? 'no file' : !$s->{readable} ? 'not a JSON object, not read' : !$s->{set} ? 'no statusLine'
                 : $s->{class} . (defined $s->{name} ? " ($s->{name})" : '');
        my $mark = defined $v->{winner} && $v->{winner} eq $s->{scope} ? ' <- Claude Code runs this one' : '';
        push @out, "status line, $s->{scope}: $what · " . util::text($s->{file}) . $mark;
    }
    push @out, 'status line in use: ' . (defined $v->{winner} ? "$v->{class}, from the $v->{winner} settings" : 'none');
    push @out, 'note: managed settings (set by an administrator) are not read here; a statusLine there wins over these';
    push @out, 'note: the meter\'s path ' . util::text($v->{shim}{path} // '(no home folder)') . ' does not exist yet: a session of the installed plugin writes it at its start, and until then the meter shows nothing'
        unless $v->{shim}{exists};
    if (defined $v->{live}) {
        my $l = $v->{live};
        push @out, $l->{utf8} ne '' ? "this session now: $l->{utf8}   (ASCII: $l->{ascii})"
                 : "this session now: nothing to show ($l->{state}" . (defined $l->{why} ? ", $l->{why}" : '') . (defined $l->{ttl} ? '' : ', no TTL') . ')';
    }
    push @out, 'samples (UTF-8 | ASCII):';
    push @out, sprintf('  %-24s | %-24s | %s', $_->{utf8}, $_->{ascii}, $_->{name}) for @{ $v->{samples} };
    push @out, 'the command: ' . $v->{command} . ' (--note-usage records the usage limits the status line shows, for the plugin\'s near-limit checks; leave it out to keep it read-only)';
    push @out, 'flags: --short (c 14m), --left (time left instead of the age), --ascii, --color auto|always|never';
    push @out, "snippet ($v->{snippet}{case}):", @{ $v->{snippet}{lines} };
    return @out;
}

1;

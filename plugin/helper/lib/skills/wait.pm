package skills::wait;
# lib/skills/wait.pm: `wait --for <cond>... [--while <guard>...] [--max S] [--stall S]
# [--deadline EPOCH]` (Dev-7 D2; REVIEW A-1 item 3, B-15; DP-14 (4)). A bounded condition
# wait the skills run instead of sleeps: in the background in the main session, in the
# foreground (--max 270) in a subagent, `--max 0` for a one-shot probe.
#   cond   pid-exit:<pid>[@<start-epoch>] | file:<path> | marker:<path>:<perl-regex> | exit:<path>
#   guard  pid:<pid>[@<start-epoch>] | file:<path>
# Met when any --for holds; exit 12 as soon as a --while stops holding. exit: matches the
# spec's exit_markers whose `active` is true (`__exit N`, the runtime's `[exited with code
# N]`: rc=N) and, for an entry with `means: killed` (`[killed]`, DP-24 (b)), prints
# `killed`, never an rc. The runtime writes its trailer without a newline (P-D1-2), so
# exit: also reads the last unterminated line. Every grammar, limit and exit code comes
# from the spec's `wait` object; a missing key refuses (fail closed).
# Order per tick: conditions, guards, stall, deadline, cap. Polls every 0.25 s for the
# first 2 s, then every 1 s, inside this process (no model-visible sleep).
# Files: marker/exit read only the bytes appended since the last check and keep a partial
# last line for the next one; a shrink or a new inode rescans from 0; the first scan
# covers at most first_scan_max_bytes (note first-scan-cut). A path that is not a regular
# file (FIFO, device, directory) is refused before any open: `REFUSED: not-regular <path>`.
# Marker regexes (B-15): at most marker_regex_max_chars, none of marker_regex_forbidden,
# must compile, else exit 64; alarm(max + alarm_slack_s) ends any overrun with exit 70.
# Guarantees: read-only (no file, row or lock), no child process but `ps`, exactly one
# stdout line (matched text cut to match_text_max_chars, never the whole line), exits by
# itself by --max; SIGINT/SIGTERM end it at once (128 + signal).
use strict;
use warnings;
use POSIX ();
use Fcntl qw(O_RDONLY O_NONBLOCK S_ISREG);
use skills::util;
use skills::cli;
use skills::spec;

my @NEED = qw(wait.cond_res wait.guard_res wait.max_range_s wait.max_default_s wait.exit_markers
              wait.marker_regex_max_chars wait.marker_regex_forbidden wait.match_text_max_chars
              wait.first_scan_max_bytes wait.alarm_slack_s wait.exit_codes);
my @CODES = qw(done pending stalled ended overdue refused usage internal);

my $HIRES = eval { require Time::HiRes; 1 } ? 1 : 0;
my $MONO = $HIRES && eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 } ? 1 : 0;
sub _clock { return $MONO ? Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) : ($HIRES ? Time::HiRes::time() : time()) }
sub _sleep { my ($s) = @_; return if $s <= 0; if ($HIRES) { Time::HiRes::sleep($s) } else { select(undef, undef, undef, $s) } }

sub _int_in { my ($v, $lo, $hi) = @_; return defined $v && $v =~ /\A[0-9]+\z/ && $v >= $lo && $v <= $hi }

sub run {
    my ($argv) = @_;
    my $need = eval { skills::spec::need(@NEED); 1 };
    die skills::cli::refuse($@ =~ s/\s+\z//r) unless $need;
    my $W = skills::spec::get('wait');
    my %X = map { ($_ => $W->{exit_codes}{$_}) } @CODES;
    for (@CODES) { die skills::cli::refuse("spec-missing wait.exit_codes.$_") unless _int_in($X{$_}, 0, 255) }

    my $o = skills::cli::opts($argv, 'for=s@', 'while=s@', 'max=s', 'stall=s', 'deadline=s');
    die skills::cli::usage("unexpected argument $argv->[0]") if @$argv;
    die skills::cli::usage('--for <cond> is required') unless $o->{for} && @{ $o->{for} };
    my ($lo, $hi) = @{ $W->{max_range_s} };
    my $max = $o->{max} // $W->{max_default_s};
    die skills::cli::usage("--max must be a whole number of seconds from $lo to $hi") unless _int_in($max, $lo, $hi);
    my $stall = $o->{stall};
    die skills::cli::usage("--stall must be a whole number of seconds from 1 to $hi") if defined $stall && !_int_in($stall, 1, $hi);
    my $deadline = $o->{deadline};
    die skills::cli::usage('--deadline must be an epoch in seconds') if defined $deadline && $deadline !~ /\A[0-9]{1,12}\z/;

    my @conds  = map { _parse_cond($W, $_) } @{ $o->{for} };
    my @guards = map { _parse_guard($W, $_) } @{ $o->{while} || [] };
    my @watched = grep { $_->{kind} eq 'marker' || $_->{kind} eq 'exit' } @conds;
    die skills::cli::usage('--stall needs a marker: or exit: condition') if defined $stall && !@watched;
    my @exit_res = map { { re => qr/$_->{re}/, killed => (($_->{means} // '') eq 'killed' ? 1 : 0) } }
                   grep { ref $_ eq 'HASH' && _true($_->{active}) && defined $_->{re} } @{ $W->{exit_markers} };

    # B-15: no pattern runs past the cap. The regex engine checks signals between steps.
    local $SIG{ALRM} = sub { print STDERR "wait: overrun past --max $max s\n"; POSIX::_exit($X{internal}) };
    local $SIG{INT}  = sub { POSIX::_exit(128 + 2) };
    local $SIG{TERM} = sub { POSIX::_exit(128 + 15) };
    alarm($max + $W->{alarm_slack_s});

    my $cut = $W->{match_text_max_chars};
    my %ctx = (first_max => $W->{first_scan_max_bytes}, exit_res => \@exit_res, notes => []);
    my $t0 = _clock();
    my $first = 1;
    while (1) {
        my $el = _clock() - $t0;
        for my $c (@conds) {
            my $hit = _check_cond($c, \%ctx, $first) or next;
            my @n = (@{ $hit->{notes} || [] }, @{ $ctx{notes} });
            my %seen;
            @n = grep { !$seen{$_}++ } @n;
            my $line = sprintf('wait: done %s after %ds', $c->{spec}, int($el));
            $line .= " rc=$hit->{rc}" if defined $hit->{rc};
            $line .= ' killed' if $hit->{killed};
            $line .= " line=$hit->{line}" if defined $hit->{line};
            $line .= ' match=' . _cut($hit->{match}, $cut) if defined $hit->{match};
            $line .= ' note=' . join(',', @n) if @n;
            return _end($line, $X{done});
        }
        for my $g (@guards) {
            my $why = _guard_broken($g, \%ctx, $first) or next;
            return _end(sprintf('wait: ended %s (%s) before %s', $g->{spec}, $why, join(' or ', map { $_->{spec} } @conds)), $X{ended});
        }
        $first = 0;
        if (defined $stall) {
            my $last = (sort { $b <=> $a } map { $_->{grew_at} // $t0 } @watched)[0];
            my $quiet = _clock() - $last;
            return _end(sprintf('wait: stalled %s no growth for %ds', $watched[0]{path}, int($quiet)), $X{stalled}) if $quiet >= $stall;
        }
        return _end(sprintf('wait: overdue deadline %s passed', skills::util::iso_local($deadline)), $X{overdue})
            if defined $deadline && skills::util::now() >= $deadline;
        $el = _clock() - $t0;
        return _end(sprintf('wait: pending after %ds (max %ds); run the same command again', int($el), $max), $X{pending}) if $el >= $max;
        my $step = $el < 2 ? 0.25 : 1;
        $step = $max - $el if $max - $el < $step;
        _sleep($step);
    }
}

sub _true { my ($v) = @_; return 0 unless defined $v; return ref $v ? ($$v ? 1 : 0) : ($v && $v ne 'false' ? 1 : 0) }

sub _end { my ($line, $rc) = @_; skills::cli::say($line); alarm 0; return $rc }

sub _cut {
    my ($t, $n) = @_;
    my $c = $t;
    # characters out (P5-FOLD A4); bytes that are not UTF-8 are shown as ASCII only
    if (utf8::is_utf8($c) || utf8::decode($c)) { $c = substr($c, 0, $n) if length $c > $n; $c =~ s/[\x00-\x1f\x7f]/?/g; return $c }
    $t = substr($t, 0, $n) if length $t > $n;
    $t =~ s/[^\x20-\x7e]/?/g;
    return $t;
}

sub _parse_cond {
    my ($W, $spec) = @_;
    for my $kind (sort keys %{ $W->{cond_res} }) {
        my $re = $W->{cond_res}{$kind};
        my @m = $spec =~ /$re/ or next;
        if ($kind eq 'pid-exit') { return _pid($spec, $kind, $m[0], $m[2]) }
        if ($kind eq 'marker') { return { kind => $kind, spec => $spec, path => $m[0], re => _marker_re($W, $m[1]) } }
        return { kind => $kind, spec => $spec, path => $m[0] };
    }
    die skills::cli::usage("bad condition $spec");
}

sub _parse_guard {
    my ($W, $spec) = @_;
    for my $kind (sort keys %{ $W->{guard_res} }) {
        my $re = $W->{guard_res}{$kind};
        my @m = $spec =~ /$re/ or next;
        return _pid($spec, $kind, $m[0], $m[2]) if $kind eq 'pid';
        return { kind => $kind, spec => $spec, path => $m[0] };
    }
    die skills::cli::usage("bad guard $spec");
}

sub _pid {
    my ($spec, $kind, $pid, $start) = @_;
    die skills::cli::usage("bad pid in $spec") unless $pid =~ /\A[1-9][0-9]{0,9}\z/;
    return { kind => $kind, spec => $spec, pid => 0 + $pid, start => (defined $start ? 0 + $start : undef), given => defined $start };
}

sub _marker_re {
    my ($W, $src) = @_;
    my $lim = $W->{marker_regex_max_chars};
    die skills::cli::usage("marker regex longer than $lim chars") if length($src) > $lim;
    for my $bad (@{ $W->{marker_regex_forbidden} }) {
        die skills::cli::usage("marker regex holds $bad") if index($src, $bad) >= 0;
    }
    my $re = eval { qr/$src/ };
    die skills::cli::usage('marker regex does not compile') unless $re;
    return $re;
}

# ---- pids

# start(pid) -> epoch of the process start, or undef (identity::start_epoch: /proc on Linux,
# so a slim image without ps still tells a reused pid; else ps -o lstart=, /bin/ps first).
# Not cached, so a reused pid shows a new start.
sub _start {
    my ($pid) = @_;
    return identity::start_epoch($pid, ps => (-x '/bin/ps' ? '/bin/ps' : undef));
}

sub _running {
    my ($pid) = @_;
    waitpid($pid, POSIX::WNOHANG());    # our own child (a test's job): reap it, so it reads gone
    return (kill(0, $pid) || $!{EPERM}) ? 1 : 0;
}

# pid_state(p, ctx, first) -> 'alive' | 'gone' | 'reused'. Without @<start> the start
# time is anchored at the first check (note pid-unanchored). lstart has 1 s resolution.
sub _pid_state {
    my ($p, $ctx, $first) = @_;
    return 'gone' unless _running($p->{pid});
    if ($first && !$p->{given}) {
        $p->{start} = _start($p->{pid});
        push @{ $ctx->{notes} }, 'pid-unanchored' unless grep { $_ eq 'pid-unanchored' } @{ $ctx->{notes} };
        return 'alive';
    }
    return 'alive' unless defined $p->{start};
    my $now = _start($p->{pid});
    return _running($p->{pid}) ? 'alive' : 'gone' unless defined $now;
    return abs($now - $p->{start}) <= 1 ? 'alive' : 'reused';
}

# ---- files

# kind_of(path) -> 'missing' | 'regular'; dies REFUSED for anything else (no open).
sub _kind_of {
    my ($path) = @_;
    my @st = stat($path);
    if (!@st) {
        return 'missing' if $!{ENOENT} || $!{ENOTDIR};
        die skills::cli::refuse("unreadable $path");
    }
    die skills::cli::refuse("not-regular $path") unless S_ISREG($st[2]);
    return 'regular';
}

sub _check_cond {
    my ($c, $ctx, $first) = @_;
    if ($c->{kind} eq 'pid-exit') {
        my $s = _pid_state($c, $ctx, $first);
        return undef if $s eq 'alive';
        return { notes => ['not-running-at-start'] } if $first && $s eq 'gone';
        return { notes => ($s eq 'reused' ? ['reused'] : []) };
    }
    my $k = _kind_of($c->{path});
    return ($k eq 'regular' ? {} : undef) if $c->{kind} eq 'file';
    if ($k eq 'missing') { $c->{seen_missing} = 1; return undef }
    return _scan($c, $ctx);
}

# _exit_hit(ctx, line, n, notes) -> {line, rc | killed, notes} for the first active exit
# marker the line matches, or undef.
sub _exit_hit {
    my ($ctx, $l, $n, $notes) = @_;
    for my $e (@{ $ctx->{exit_res} }) {
        next unless $l =~ $e->{re};
        return { line => $n, killed => 1, notes => $notes } if $e->{killed};
        return { line => $n, rc => 0 + $1, notes => $notes } if defined $1;
    }
    return undef;
}

sub _guard_broken {
    my ($g, $ctx, $first) = @_;
    if ($g->{kind} eq 'pid') { my $s = _pid_state($g, $ctx, $first); return $s eq 'alive' ? undef : $s }
    return _kind_of($g->{path}) eq 'regular' ? undef : 'deleted';
}

# scan(cond, ctx) -> a hit {line, match | rc | killed, notes} or undef. Reads the new bytes
# of a marker/exit file line by line; for marker: the last line counts only once it ends in
# a newline, for exit: an unterminated last line is read too (the runtime trailer).
sub _scan {
    my ($c, $ctx) = @_;
    sysopen(my $fh, $c->{path}, O_RDONLY | O_NONBLOCK) or die skills::cli::refuse("unreadable $c->{path}");
    my @st = stat($fh);
    die skills::cli::refuse("not-regular $c->{path}") unless @st && S_ISREG($st[2]);
    my ($ino, $size) = ("$st[0]:$st[1]", $st[7]);
    my @notes;
    if (!defined $c->{pos}) {
        @$c{qw(pos partial line ino size)} = (0, '', 0, $ino, $size);
        $c->{grew_at} = _clock() if $c->{seen_missing} && $size;
        if ($size > $ctx->{first_max}) {
            # Start inside the last window; the line cut there is skipped unless the
            # window begins right after a newline.
            $c->{pos} = $size - $ctx->{first_max};
            sysseek($fh, $c->{pos} - 1, 0);
            my $got = sysread($fh, my $prev, 1);
            $c->{skip_partial} = ($got && $prev eq "\n") ? 0 : 1;
            push @{ $ctx->{notes} }, 'first-scan-cut';
        }
    } elsif ($ino ne $c->{ino} || $size < $c->{pos}) {
        @$c{qw(pos partial line ino)} = (0, '', 0, $ino);
        $c->{skip_partial} = 0;
        $c->{grew_at} = _clock();
        push @notes, 'rescanned';
    }
    $c->{grew_at} = _clock() if $size != $c->{size};
    $c->{size} = $size;
    sysseek($fh, $c->{pos}, 0) or die skills::cli::refuse("unreadable $c->{path}");
    while (1) {
        my $n = sysread($fh, my $buf, 1 << 20);
        die skills::cli::refuse("unreadable $c->{path}") unless defined $n;
        last if $n == 0;
        $c->{pos} += $n;
        my $text = $c->{partial} . $buf;
        my $nl = rindex($text, "\n");
        if ($nl < 0) {
            # A line longer than 4 MiB is never matched: drop it and skip to its end.
            ($c->{partial}, $c->{skip_partial}) = length($text) > (1 << 22) ? ('', 1) : ($text, $c->{skip_partial});
            next;
        }
        $c->{partial} = substr($text, $nl + 1);
        my @lines = $nl ? split(/\n/, substr($text, 0, $nl), -1) : ('');
        for my $l (@lines) {
            if ($c->{skip_partial}) { $c->{skip_partial} = 0; next }
            $c->{line}++;
            $l =~ s/\r\z//;
            $l = skills::util::text($l);
            if ($c->{kind} eq 'marker') {
                return { line => $c->{line}, match => $&, notes => \@notes } if $l =~ $c->{re};
            } else {
                my $hit = _exit_hit($ctx, $l, $c->{line}, \@notes);
                return $hit if $hit;
            }
        }
    }
    close $fh;
    if ($c->{kind} eq 'exit' && !$c->{skip_partial} && $c->{partial} ne '') {
        (my $l = $c->{partial}) =~ s/\r\z//;
        $l = skills::util::text($l);
        my $hit = _exit_hit($ctx, $l, $c->{line} + 1, \@notes);
        return $hit if $hit;
    }
    if (@notes) { push @{ $ctx->{notes} }, grep { my $n = $_; !grep { $_ eq $n } @{ $ctx->{notes} } } @notes }
    return undef;
}

1;

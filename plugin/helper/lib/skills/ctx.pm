package skills::ctx;
# lib/skills/ctx.pm: per-run context for the skill subcommands: plugin root,
# brand and version, settings, paths, session identity, per-process records,
# lineage and pins (TPL §6, MOD §7).
use strict;
use warnings;
use utf8;
use File::Basename ();
use Cwd ();
use skills::util;
use skills::core;

my $ROOT;
sub plugin_root {
    return $ROOT if defined $ROOT;
    my $here = File::Basename::dirname(Cwd::abs_path(__FILE__));    # helper/lib/skills
    $ROOT = Cwd::abs_path("$here/../../..");
    return $ROOT;
}

my $MANIFEST;
sub manifest {
    return $MANIFEST if $MANIFEST;
    my $t = skills::util::read_file(plugin_root() . '/.claude-plugin/plugin.json');
    my $m = eval { skills::util::json_decode($t) } || {};
    $MANIFEST = ref $m eq 'HASH' ? $m : {};
    return $MANIFEST;
}

sub brand   { return manifest()->{name} // 'store' }
sub version { return manifest()->{version} // '0.0.0' }

# Build the context. $flags: userConfig-key => raw flag value (may be unset).
sub new {
    my ($flags, %o) = @_;
    my %clean;
    my %notes;
    for my $k (sort keys %{ $flags || {} }) {
        my $v = $flags->{$k};
        next unless defined $v;
        if (skills::util::unset_value($v)) {
            $notes{$k} = $v =~ /\A\$\{/ ? 'unsubstituted; default used' : 'empty; default used';
            next;
        }
        $clean{$k} = $k =~ /_root\z|_dir\z|_cmd\z/ ? skills::util::expand_tilde($v) : $v;
    }
    my $s = skills::core::settings(\%clean);
    my $ctx = {
        settings => $s,
        flags    => \%clean,
        notes    => \%notes,
        version  => version(),
        brand    => brand(),
        actor    => 'main',
    };
    my $p = skills::core::paths($s, 'unknown');
    $ctx->{root}       = $p->{root};
    $ctx->{watch}      = $p->{watch};
    $ctx->{disposable} = $p->{disposable};
    # STATE-ROOT: the legacy root (~/.claude/handoffs while handoff_root is the default), read only; the run
    # context checked it (rc::init), so a refused one is undef here and legacy_refused says why.
    $ctx->{legacy}         = defined &rc::legacy ? rc::legacy() : undef;
    $ctx->{legacy_refused} = defined &rc::legacy_refused ? rc::legacy_refused() : undef;
    $ctx->{legacy_path}    = defined &rc::legacy_path ? rc::legacy_path() : undef;
    $ctx->{sid}        = 'unknown';
    return bless $ctx, __PACKAGE__;
}

sub set_sid {
    my ($ctx, $sid) = @_;
    $ctx->{sid} = $sid;
    skills::core::bind_sid($sid);
    my $p = skills::core::paths($ctx->{settings}, $sid);
    $ctx->{watch} = $p->{watch};
    return $sid;
}

sub log { my ($ctx, $ev, $f) = @_; return skills::core::log_event($ctx, $ev, $f) }

sub sid8 { my ($sid) = @_; my $s = $sid // ''; $s =~ s/[^0-9A-Za-z]//g; return lc substr($s, 0, 8) }

sub valid_sid { my ($v) = @_; return defined $v && $v =~ /\A[0-9A-Za-z][0-9A-Za-z_-]{7,63}\z/ }

# placeholder_sid(value) -> 1 for a given --sid that is never this session's id (CW-1 review 2):
# the plugin's own placeholders (`anon-*`, this file's identity without a session id, which
# begin prints and degraded handoffs carry; `unknown`; `smoke`) and a variable name or `$`
# reference left unsubstituted (a bare `CLAUDE_*`). The same set as lib/args.pm reserved_sid
# with unsubstituted; resolve_sid takes such a value as unset.
sub placeholder_sid {
    my ($v) = @_;
    return defined $v && ($v =~ /\Aanon-/ || $v eq 'unknown' || $v eq 'smoke' || $v =~ /\A\s*\$/
                          || $v =~ /\ACLAUDE_[A-Z0-9_]+\z/) ? 1 : 0;
}

# ---------------------------------------------------------------- per-process records

sub records_dir { my ($ctx) = @_; return "$ctx->{root}/.sessions/by-pid" }

# read_roots(ctx) -> the store root, then the legacy root when there is one (STATE-ROOT). Every reader of
# the store's own files looks in both, in this order (the store root's file wins for one name);
# writers use $ctx->{root} only.
sub read_roots { my ($ctx) = @_; return grep { defined && $_ ne '' } ($ctx->{root}, $ctx->{legacy}) }

# All records: [{pid, epoch, state(live|ended), sid8, path, data}], from both read roots (a
# record file in both counts once, the store root's).
sub records {
    my ($ctx, $sid8) = @_;
    my @out;
    my %seen;
    for my $dir (map { "$_/.sessions/by-pid" } read_roots($ctx)) {
        for my $f (skills::util::list_dir($dir)) {
            next unless $f =~ /\A(\d+)-(\d+)\.(live|ended)-([0-9a-z]+)\.json\z/;
            my ($pid, $epoch, $state, $s8) = ($1, $2, $3, $4);
            # An optional sid8 keeps only that session's files, before any is read.
            next if defined $sid8 && $s8 ne $sid8;
            next if $seen{$f}++;
            my $d = eval { skills::util::json_decode(skills::util::read_file("$dir/$f", 65536)) };
            push @out, { pid => $pid, epoch => $epoch, state => $state, sid8 => $s8, path => "$dir/$f", data => (ref $d eq 'HASH' ? $d : {}) };
        }
    }
    return \@out;
}

sub _norm_ls { my ($v) = @_; return '' unless defined $v; $v =~ s/\s+/ /g; $v =~ s/\A | \z//g; return $v }

# A recorded session is live when its pid runs with the same start time and
# it has no ended- record (MOD §7).
sub record_live {
    my ($ctx, $rec, $all) = @_;
    my $sid = $rec->{data}{session_id} // '';
    for my $o (@{ $all || records($ctx) }) {
        next unless $o->{state} eq 'ended' && $o->{pid} eq $rec->{pid} && $o->{epoch} eq $rec->{epoch};
        return 0 if ($o->{data}{session_id} // '') eq $sid || $o->{sid8} eq $rec->{sid8};
    }
    return pid_matches($rec->{pid}, $rec->{data}{pid_lstart});
}

# 1 when the pid runs and its start time equals the recorded one.
sub pid_matches { return pid_state(@_) eq 'match' ? 1 : 0 }

# CR-F11: match (the pid runs with the recorded start time) | gone (no such pid, or its
# start time differs) | unverified (the pid runs, but the recorded start time is missing
# or `ps` could not read the current one). Only `gone` proves the recorded process ended.
sub pid_state {
    my ($pid, $recorded) = @_;
    return 'gone' unless defined $pid && $pid =~ /\A\d+\z/ && $pid > 0;
    my $alive = kill(0, $pid) ? 1 : ($!{EPERM} ? 1 : 0);
    return 'gone' unless $alive;
    return 'unverified' unless defined $recorded && $recorded ne '';
    my $now = skills::core::lstart($pid);
    return 'unverified' unless defined $now;
    return _norm_ls($now) eq _norm_ls($recorded) ? 'match' : 'gone';
}

# The live record of the Claude Code process this helper runs under: a live-
# record of this pid and start time with no ended- record (MOD §7), newest
# by time (an epoch compare, so a DST change cannot reorder them).
sub own_record {
    my ($ctx) = @_;
    my $cp = skills::core::claude_pid();
    return (undef, undef) unless $cp;
    my $all = records($ctx);
    my %ended = map { ("$_->{pid}-$_->{epoch}-$_->{sid8}" => 1) } grep { $_->{state} eq 'ended' } @$all;
    my @mine = grep {
        $_->{state} eq 'live' && $_->{pid} eq $cp->{pid}
            && _norm_ls($_->{data}{pid_lstart}) eq _norm_ls($cp->{lstart})
            && !$ended{"$_->{pid}-$_->{epoch}-$_->{sid8}"}
    } @$all;
    @mine = sort { (skills::util::iso_to_epoch($b->{data}{ts}) // 0) <=> (skills::util::iso_to_epoch($a->{data}{ts}) // 0) } @mine;
    return ($mine[0], $cp);
}

# Session identity (TPL §6): the record, cross-checked with the passed id.
# The passed id is a cross-check only (HDN §8): on a mismatch the record
# wins and the identity is marked degraded. A placeholder (placeholder_sid) is taken as unset
# (CW-1 review 2): the record, else a fresh anon- id marked degraded (no-session-id).
# Returns {sid, sid8, source, degraded, pid, lstart}.
sub resolve_sid {
    my ($ctx, $flag) = @_;
    my $given = (defined $flag && !skills::util::unset_value($flag) && !placeholder_sid($flag) && valid_sid($flag))
              ? $flag : undef;
    my ($rec, $cp) = own_record($ctx);
    my $rsid = $rec ? $rec->{data}{session_id} : undef;
    $rsid = undef unless valid_sid($rsid);
    my %id = (pid => ($cp ? $cp->{pid} : undef), lstart => ($cp ? $cp->{lstart} : undef), degraded => undef);
    if ($given && $rsid && $given ne $rsid) {
        @id{qw(sid source degraded)} = ($rsid, 'record', 'sid-mismatch');
    } elsif ($given) {
        @id{qw(sid source)} = ($given, $rsid ? 'flag+record' : 'flag');
    } elsif ($rsid) {
        @id{qw(sid source)} = ($rsid, 'record');
    } else {
        @id{qw(sid source degraded)} = ('anon-' . skills::util::rand_hex(8), 'token', 'no-session-id');
    }
    $id{sid8} = sid8($id{sid});
    set_sid($ctx, $id{sid});
    return \%id;
}

# Live peers: other sessions with a live record on this worktree (OD-16).
sub live_peers {
    my ($ctx, $worktree, $sid) = @_;
    my $all = records($ctx);
    my @peers;
    my %seen;
    for my $r (grep { $_->{state} eq 'live' } @$all) {
        my $rs = $r->{data}{session_id} // '';
        next if $rs eq ($sid // '') || $seen{$rs}++;
        my $wt = $r->{data}{worktree} // $r->{data}{cwd} // '';
        next if defined $worktree && $wt ne $worktree;
        next unless record_live($ctx, $r, $all);
        push @peers, { sid8 => sid8($rs), pid => 0 + $r->{pid}, session_id => $rs };
    }
    return \@peers;
}

# ---------------------------------------------------------------- lineage and pins

# The lineage link of sid: the first read root that holds one (STATE-ROOT: the store root's wins).
sub lineage_of {
    my ($ctx, $sid) = @_;
    for my $r (read_roots($ctx)) {
        my $p = "$r/.sessions/$sid.lineage.json";
        next unless -e $p;
        my $d = eval { skills::util::json_decode(skills::util::read_file($p, 65536)) };
        return ref $d eq 'HASH' ? $d : undef;
    }
    return undef;
}

# Predecessors up to 3 hops, same chain only (A-6).
sub chain {
    my ($ctx, $sid, $max) = @_;
    $max //= 3;
    my @out;
    my %seen = ($sid => 1);
    my $cur = $sid;
    for (1 .. $max) {
        my $l = lineage_of($ctx, $cur) or last;
        my $p = $l->{previous_session_id};
        last unless valid_sid($p) && !$seen{$p}++;
        push @out, { sid => $p, reason => $l->{lineage_reason} // 'none' };
        $cur = $p;
    }
    return \@out;
}

# The pin's path in the store root (where pin_update writes it).
sub pin_path { my ($ctx, $sid) = @_; return "$ctx->{root}/.sessions/$sid.json" }

# The pin of sid: the store root's, else the legacy root's (STATE-ROOT: a session that started before
# 0.1.2 keeps its pin; the store root's wins). pin_update starts from it and writes the store root.
sub pin_read {
    my ($ctx, $sid) = @_;
    for my $r (read_roots($ctx)) {
        my $p = "$r/.sessions/$sid.json";
        next unless -e $p;
        my $d = eval { skills::util::json_decode(skills::util::read_file($p, 65536)) };
        return ref $d eq 'HASH' ? $d : undef;
    }
    return undef;
}

# Read-modify-write of .sessions/<sid>.json under the TPL §6 lock.
# $fn receives the current pin (or {}) and returns the new one.
# Returns ($ok, $pin_or_error).
sub pin_update {
    my ($ctx, $sid, $fn) = @_;
    my $path = pin_path($ctx, $sid);
    skills::util::mkdir_p("$ctx->{root}/.sessions");
    my $owner = skills::core::lock_owner($sid, $ctx->{actor});
    return skills::core::with_lock("$path.lock", $owner, sub {
        my $cur = pin_read($ctx, $sid) || {};
        my $new = $fn->($cur);
        $new->{session_id} = $sid;
        $new->{updated}    = skills::util::iso_local();
        skills::util::write_replace($path, skills::util::json_encode($new) . "\n", 0600);
        return $new;
    });
}

1;

# cmd/migrate.pl: `migrate [--apply]` (STATE-ROOT, 0.1.2). Owner: WP-core. User-run only: no hook,
# skill or mod calls it.
# While handoff_root or disposable_root is the default, the old default folder (~/.claude/handoffs,
# ~/.claude/trash-staging) is read beside the new one and never written. migrate COPIES what an old
# folder holds into the new one, so the old folder can later be removed by hand (a full path recorded under it,
# in MANIFEST.tsv or a pin, is then read under the new folder: skills::ctx::follow):
#   - a dry run by default: it lists what it would copy and writes nothing; --apply copies;
#   - it never deletes, moves or overwrites (D-8): a file already in the new folder is left as it is
#     (`same` bytes, or `differs`, listed); links and special files are skipped, never followed;
#   - copies keep their owner mode bits (so they stay private: folders 0700) and their mtime;
#   - a copy is written under a temp name and linked into place (util::copy_new), so a failed copy
#     leaves nothing under the file's name and a rerun copies it again;
#   - what is live or unfinished in the old handoff root is left out (%LEFT_OUT): unfinished drafts
#     (.staging), the watcher's own folder (.watch), the per-process records (.sessions/by-pid) and
#     pin locks (.sessions/*.lock); a copy of them would show a draft twice or a stale lock;
#   - a root set to any other value (the old default included) is never changed: nothing is copied
#     for it; an old folder the unsafe-root checks refuse is skipped, and so is a refused new root.
# Exit 0; 3 when a new root is refused or a copy failed; 64 usage.
use strict;
use warnings;
use utf8;

package cmd_migrate;

our $LIST_MAX = 10;

# (key, label) of the two settings whose default left ~/.claude
my @PAIRS = (['handoff_root', 'handoff_root'], ['disposable_root', 'disposable_root']);

# key -> sub(rel path, is a folder) -> 1 for an entry migrate leaves out (see the head comment)
our %LEFT_OUT = (
    handoff_root => sub {
        my ($r, $dir) = @_;
        return $dir ? ($r eq '.watch' || $r eq '.sessions/by-pid' || $r =~ m{(?:\A|/)\.staging\z} ? 1 : 0)
                    : ($r =~ m{\A\.sessions/[^/]+\.lock\z} ? 1 : 0);
    },
    disposable_root => sub { 0 },
);

sub _show { my ($p) = @_; return util::text(util::abbrev($p)) }

sub _mb { my ($b) = @_; return sprintf('%.1f MB', ($b // 0) / 1048576) }

# walk(old, new, rel, skip_real, acc, apply, left_out): one folder of the old root, depth first, by lstat.
sub _walk {
    my ($old, $new, $rel, $skip, $acc, $apply, $left) = @_;
    my $dir = $rel eq '' ? $old : "$old/$rel";
    for my $e (util::list_dir($dir)) {
        my $r = $rel eq '' ? $e : "$rel/$e";
        my $src = "$old/$r";
        my @st = lstat $src;
        next unless @st;
        if (-l _ || (!-f _ && !-d _)) { $acc->{skipped}++; next }
        if ($left->($r, -d _)) { $acc->{left_out}++; next }
        if (-d _) {
            my $real = util::real_path($src);
            next if defined $real && defined $skip && $real eq $skip;    # the new root inside the old one
            _walk($old, $new, $r, $skip, $acc, $apply, $left);
            next;
        }
        my $dst = "$new/$r";
        my @dt = lstat $dst;
        if (@dt) {
            my $same = -f _ && $dt[7] == $st[7] && (sha::hex256_file($dst) // '') eq (sha::hex256_file($src) // 'x');
            if ($same) { $acc->{same}++ } else { $acc->{differs}++; push @{ $acc->{differ_list} }, $r }
            next;
        }
        $acc->{files}++;
        $acc->{bytes} += $st[7];
        next unless $apply;
        my $mode = ($st[2] & 0700) || 0600;
        my $n = eval { util::copy_new($src, $dst, mode => $mode, times => [$st[8], $st[9]]) };
        if (!defined $n) {
            (my $why = $@ // 'error') =~ s/\s+\z//;
            $acc->{failed}++;
            push @{ $acc->{failed_list} }, "$r ($why)";
        } elsif ($n < 0) {
            $acc->{differs}++;    # appeared meanwhile: left as it is
            push @{ $acc->{differ_list} }, $r;
        } else {
            $acc->{copied}++;
        }
    }
    return;
}

sub _list {
    my ($label, $items) = @_;
    my @l = @{ $items || [] };
    return () unless @l;
    my @out = map { "    $label: " . util::text($_) } @l[0 .. ($#l < $LIST_MAX - 1 ? $#l : $LIST_MAX - 1)];
    push @out, '    (+' . (@l - $LIST_MAX) . ' more)' if @l > $LIST_MAX;
    return @out;
}

sub run {
    my ($opt, $rest) = args::parse(\@_, known => [qw(root log-dir disposable-root)], bools => [qw(apply)]);
    die "usage: migrate [--apply]\n" if @$rest;
    my $apply = $opt->{apply} ? 1 : 0;
    my %flags = %$opt;
    delete $flags{apply};
    rc::init(sid => 'unknown', writer => 'helper', flags => settings::flags_from(\%flags));
    my $p = rc::paths();
    my @out = ($apply ? 'migrate: copying (nothing is deleted, moved or overwritten)'
                      : 'migrate: dry run, nothing written (add --apply to copy; nothing is ever deleted, moved or overwritten)');
    my $code = 0;
    for my $pair (@PAIRS) {
        my ($key, $label) = @$pair;
        my $is_disp = $key eq 'disposable_root';
        my $new = $is_disp ? $p->{disposable} : $p->{root};
        my $from_def = $is_disp ? $p->{disposable_from_default} : $p->{from_default};
        my $old_path = util::clean_path($paths::MOVED{$key}[1]);
        if (!$from_def) {
            push @out, "$label: set to " . (defined $new ? _show($new) : 'nothing') . '; only that folder is used, nothing to copy';
            next;
        }
        my $old = $is_disp ? rc::disposable_legacy() : rc::legacy();
        my $refused = $is_disp ? rc::disposable_legacy_refused() : rc::legacy_refused();
        if (!defined $old) {
            push @out, defined $refused
                ? "$label: old folder " . _show($old_path) . ' skipped (' . util::text($refused) . ')'
                : "$label: no old folder " . (defined $old_path ? _show($old_path) : '') . ', nothing to copy';
            next;
        }
        push @out, "$label: " . _show($old) . ' -> ' . _show($new);
        if (!rc::root_ok($key)) {
            push @out, '  new folder refused (' . util::text(rc::root_reason($key) // 'root-unsafe') . '); nothing copied';
            $code = 3;
            next;
        }
        my %acc = (files => 0, bytes => 0, same => 0, differs => 0, skipped => 0, left_out => 0, copied => 0, failed => 0);
        util::mkdir_p($new) if $apply;
        _walk($old, $new, '', util::real_path($new), \%acc, $apply, $LEFT_OUT{$key});
        my $what = $apply ? "copied: $acc{copied} files" : "to copy: $acc{files} files";
        push @out, "  $what, " . _mb($acc{bytes}) . " · already there: $acc{same} · differ, left as they are: $acc{differs}"
                   . " · links and special files skipped: $acc{skipped}"
                   . " · drafts, watcher files, live records and locks left out: $acc{left_out}"
                   . ($apply ? " · failed: $acc{failed}" : '');
        push @out, _list('differs', $acc{differ_list}), _list('failed', $acc{failed_list});
        $code = 3 if $acc{failed};
    }
    push @out, 'the old folders stay where they are and are still read while these settings are the defaults; '
               . 'once no session of an older version runs and you have checked the copies, you may remove them yourself '
               . '(paths recorded under them are then read in the new folders; unfinished drafts and watcher files left out go with them)';
    args::out(@out);
    return $code;
}

exit(args::main(\&run, @ARGV));

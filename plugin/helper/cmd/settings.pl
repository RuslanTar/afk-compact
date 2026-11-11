# cmd/settings.pl: `settings show`, `settings set` and `settings reset` (0.1.2 visible defaults,
# onboarding and the settings writer).
#   settings show [--root D] [--log-dir D] [settings flags]
#       read-only: the settings file and the plugin's options key, then every key in @KEYS order
#       with its value, source and default, the warnings (a saved "", an ambiguous key), the
#       notes, and the user-run reset line (visible defaults).
#   settings show --json | --tier common|advanced|all [settings flags]
#       read-only, the data of the onboarding settings flow: settings::view(), every key's
#       section, tier, kind, default, min/max, allowed values, current value and its source
#       (flag|env|settings|default|safe), whether the clamp moves it, consent or protective
#       class; the pluginConfigs key in use and `write_refused` (config-dir-foreign,
#       home-foreign, unreadable, unparseable, inline or ambiguous: why a write there would be
#       refused). --json prints that object on one line; --tier alone a heading per section and
#       one `  <key> = <value> (<source>)` line per key.
#   settings set <key>=<value>... [--plan P] [--apply]
#   settings reset <key>...|--all [--plan P] [--apply]
#   settings migrate [--plan P] [--apply]
#       the settings writer (lib/settings_write.pm: the helper's one writer, safe keys only):
#       a dry run unless --apply (as `project copy`), which lists each change as old -> new
#       (never a pattern's or a list's text) and the way to apply it with --plan (the file's
#       hash), so the apply refuses a file changed since. A model-run call may apply it for any
#       key but the six consent keys, which the writer refuses on every path (it cannot tell a
#       user's `!` line from a model's call); for those it prints the user-run ways. A value set
#       to its default (or empty) removes the member. --apply prints each change, the backup next
#       to the file and when it takes effect.
#       migrate (0.1.6): the values saved in a form from before 0.1.6 (settings::old_values:
#       an on/off key's old word, an option in another case), which Claude Code reads as unset,
#       set to their new form through the same writer; a consent key among them is listed with
#       the user-run ways, never written.
# Exit codes: 0, 3 (refused: nothing written), 64 (usage), 70.
use strict;
use warnings;
use utf8;
require "settings_write.pm";
require "settings_reset.pm";

package cmd_settings;

my $USAGE_RESET = 'usage: settings reset <key>...|--all [--apply]';
my $USAGE_SET = 'usage: settings set <key>=<value>... [--apply]';
my $USAGE_MIGRATE = 'usage: settings migrate [--apply]';

sub run {
    my $sub = shift @_;
    die "usage: settings show | settings set <key>=<value>... [--apply] | settings reset <key>...|--all [--apply] | settings migrate [--apply]\n"
        unless defined $sub && ($sub eq 'show' || $sub eq 'reset' || $sub eq 'set' || $sub eq 'migrate');
    my ($opt, $rest) = args::parse(\@_, bools => [qw(apply all json)], known => [qw(plan root log-dir tier)]);
    if ($sub eq 'show') {
        die "usage: settings show takes no argument ($rest->[0])\n" if @$rest;
        die "usage: --tier common|advanced|all\n" if defined $opt->{tier} && $opt->{tier} !~ /\A(?:common|advanced|all)\z/;
        return view($opt) if $opt->{json} || defined $opt->{tier};
    }
    rc::init(sid => undef, writer => 'helper', flags => settings::flags_from($opt));
    return show() if $sub eq 'show';
    if ($sub eq 'set') {
        die "$USAGE_SET\n" if $opt->{all} || !@$rest;
        my (@req, %seen);
        for my $a (@$rest) {
            my ($k, $v) = $a =~ /\A([A-Za-z0-9_]+)=(.*)\z/s or die "usage: settings set: $a is not <key>=<value>\n";
            die "usage: settings set: $k is no setting of this plugin\n" unless exists $settings::TYPE{$k};
            die "usage: settings set: $k given twice\n" if $seen{$k}++;
            push @req, { key => $k, kind => 'set', text => $v };
        }
        return write_cmd('set', \@req, $opt->{plan}, $opt->{apply});
    }
    if ($sub eq 'migrate') {
        die "$USAGE_MIGRATE\n" if $opt->{all} || @$rest;
        return migrate($opt->{plan}, $opt->{apply});
    }
    die "$USAGE_RESET\n" if ($opt->{all} && @$rest) || (!$opt->{all} && !@$rest);
    my %seen;
    for my $k (@$rest) {
        die "usage: settings reset: $k is no setting of this plugin\n" unless exists $settings::TYPE{$k};
        die "usage: settings reset: $k given twice\n" if $seen{$k}++;
    }
    return write_cmd('reset', $opt->{all} ? 'all' : $rest, $opt->{plan}, $opt->{apply});
}

sub _file_text { return util::text(util::abbrev(settings::config_dir() . '/settings.json')) }

sub _text {
    my ($v) = @_;
    return '(empty)' if !defined $v || (!ref $v && $v eq '');
    return "$v";
}

# The onboarding settings flow's view (--json or --tier): settings::view() as one JSON object, or
# a heading per section and one line per key.
sub view {
    my ($opt) = @_;
    my $view = settings::view(settings::flags_from($opt), $opt->{tier} // 'all');
    if ($opt->{json}) {
        print STDOUT jsonc::encode_bytes($view), "\n";
        return 0;
    }
    my %v = @$view;
    my %rows = @{ $v{settings} };
    my @out;
    for my $s (@{ $v{sections} }) {
        my %s = @$s;
        push @out, $s{title};
        for my $k (@{ $s{keys} }) {
            my %r = @{ $rows{$k} };
            my $why = $r{class} ? "; $r{class} key, settings file only" : '';
            push @out, "  $k = " . _text($r{value}) . " ($r{source}$why)";
        }
    }
    push @out, 'pluginConfigs key: ' . ($v{config_key} // "none ($v{config_key_state})");
    push @out, "writes refused: $v{write_refused}" if defined $v{write_refused};
    push @out, "note: $_" for @{ $v{notes} || [] };
    push @out, 'not in a section: ' . join(', ', @{ $v{unsectioned} }) if @{ $v{unsectioned} };
    print STDOUT map { my $l = $_; utf8::encode($l) if utf8::is_utf8($l); "$l\n" } @out;
    return 0;
}

sub show {
    my $o = settings::options_source();
    my $head = 'settings file: ' . _file_text() . ($o->{exists} ? '' : ' (none)') . ' · ';
    $head .= !$o->{exists} ? 'no plugin options saved'
           : !$o->{json} ? 'not plain JSON: the plugin reads no options from it'
           : $o->{ambiguous} ? 'several plugin option keys: every key at its default'
           : defined $o->{key} && $o->{options} ? 'plugin options under "' . util::text($o->{key}) . '"'
           : 'no plugin options saved';
    my $rows = settings::effective_rows(rc::settings());
    my @out = ($head, map { "$_->{key} " . settings::row_text($_) } @$rows);
    my $store = ctx::store_cmd();
    push @out, settings::value_warnings($rows, $store);
    push @out, map { 'note: ' . util::text($_) } @{ rc::settings()->{notes} || [] };
    push @out, 'change or reset (a dry run unless you add --apply; never a consent key): ' . util::text($store)
               . ' settings set <key>=<value>... | settings reset <key>...' if defined $store;
    args::out(@out);
    return 0;
}

my %REFUSED = (
    'not-json' => 'your settings.json is not plain JSON (comments, a trailing comma or a syntax error); edit it by hand or in /config',
    unparseable => 'your settings.json, its pluginConfigs or the plugin\'s entry there is not a JSON object; edit it by hand or in /config',
    unreadable => 'your settings.json cannot be read as a file',
    'no-file' => 'there is no settings.json yet; save a setting in /config first',
    'config-dir-foreign' => 'CLAUDE_CONFIG_DIR names another folder than ~/.claude, and the writer edits ~/.claude/settings.json only; edit that folder\'s file by hand or in /config',
    'home-foreign' => 'HOME is not your account\'s home folder, and the writer edits your own ~/.claude/settings.json only',
    inline => 'the plugin runs from --plugin-dir, so its options key there is not one Claude Code saves; use /config',
    'no-key' => 'your settings.json has no entry for the plugin and its marketplace is not known here; save one setting in /config first',
    changed => 'your settings.json changed since the dry run; run the dry run again',
    'changed-now' => 'your settings.json changed while this ran (another program wrote it); nothing written, run it again',
    verify => 'the edited text did not read back as your settings with exactly those changes; nothing written',
    'not-file' => 'your settings.json is not a regular file',
    'hard-link' => 'your settings.json has a second name (a hard link) and a write puts a new file under one name only; edit it by hand or in /config',
    backup => 'no backup could be written next to your settings.json',
    write => 'the new text could not be written; your settings.json keeps its old text',
    after => 'the file read back after the write is not the text written (another program wrote it at the same moment); check it, the backup holds the text before',
);

sub _refused_text {
    my ($p, $why) = @_;
    return 'several plugin option keys in your settings.json (' . join(', ', map { '"' . util::text($_) . '"' } @{ settings::options_source()->{candidates} || [] })
           . '); remove the one no longer used, then run this again' if $why eq 'ambiguous';
    return 'your settings.json names "' . util::text($1) . '" twice in one object; edit it by hand or in /config' if $why =~ /\Atwice:(.*)\z/s;
    return $REFUSED{$why} // "refused ($why)";
}

# The refusal: one line for the file, or a heading and a line per key (consent keys with the
# user-run ways to change them).
sub _refused {
    my ($sub, $p, $r) = @_;
    my @key = grep { defined $_->{key} } @{ $p->{refusals} || [] };
    if (!@key) {
        my $why = $r ? $r->{why} : $p->{refusals}[0]{why};
        my @l = ("settings $sub: refused, " . _refused_text($p, $why));
        push @l, "  error: $r->{error}" if $r && defined $r->{error};
        push @l, '  backup: ' . util::text(util::abbrev($r->{backup})) . ' (the file as it was)' if $r && defined $r->{backup};
        args::out(@l);
        return 3;
    }
    my @l = ("settings $sub: refused, nothing written");
    for my $x (@key) {
        if ($x->{why} eq 'consent') { push @l, settings_write::consent_lines($x, $p->{ckey}); next }
        push @l, "  $x->{key}: " . ($x->{why} eq 'loosen' ? 'looser, refused: ' : 'not valid: ') . $x->{detail};
    }
    args::out(@l);
    return 3;
}

sub _where {
    my ($p) = @_;
    return '' unless defined $p->{ckey};
    return 'plugin options under "' . util::text($p->{ckey}) . '"' . (($p->{ckey_how} // 'found') eq 'found' ? '' : ' (a new entry)');
}

sub _takes_effect {
    return "  takes effect: the plugin's helper reads the new values at its next call; Claude Code passes them to the hooks once it "
           . 'reads its settings again (whether a running session does that by itself is not checked yet: run /reload-plugins or restart Claude Code to be sure)';
}

# migrate(--plan, --apply): settings::old_values as set requests (consent keys apart), then write_cmd
sub migrate {
    my ($given, $apply) = @_;
    # two option keys for the plugin: old_values reads neither, so say why rather than "nothing"
    return _refused('migrate', { refusals => [{ why => 'ambiguous' }] }) if settings::options_source()->{ambiguous};
    my @old = grep { defined $_->{to} } settings::old_values();
    my @consent = map { settings_write::consent_lines({ key => $_->{key}, value => $_->{to} }, settings::options_source()->{key}) }
                  grep { $_->{consent} } @old;
    my @req = map { { key => $_->{key}, kind => 'set', text => $_->{to} } } grep { !$_->{consent} } @old;
    if (!@req) {
        args::out('settings migrate: nothing to change' . (@consent ? ' but the consent keys below' : ': no saved value is in a form from before 0.1.6'), @consent);
        return 0;
    }
    return write_cmd('migrate', \@req, $given, $apply, \@consent);
}

# write_cmd(set|reset|migrate, requests | keys | 'all', --plan, --apply[, extra lines])
sub write_cmd {
    my ($sub, $want, $given, $apply, $extra) = @_;
    my @extra = @{ $extra || [] };
    my $kept = [];
    my $reqs = $want;
    if ($sub eq 'reset') {
        my $o = settings::options_source();
        ($reqs, $kept) = settings_reset::requests($want, $o->{options});
    }
    my $p = settings_write::plan($reqs);
    return _refused($sub, $p) if $p->{state} eq 'refused';
    my $ft = _file_text();
    my $where = _where($p);
    my @kept = @$kept ? ('  kept by --all (consent or protective: the writer never writes a consent key, never takes an entry from a protective list and never moves resume_proceed back to true; change those in /config or the file by hand): ' . join(', ', @$kept)) : ();
    my @ns = map { $_->{why} eq 'not-saved' ? "  not saved, nothing to remove: $_->{key}" : "  unchanged: $_->{key}" } @{ $p->{same} };
    if ($p->{state} eq 'nothing') {
        my $why = !defined $p->{raw} ? " (no $ft)" : !%{ $p->{options} || {} } ? " (no plugin options in $ft)" : '';
        args::out("settings $sub: nothing to " . ($sub eq 'reset' ? 'remove' : 'change') . $why, @ns, @kept, @extra);
        return 0;
    }
    return _refused($sub, $p, { why => 'changed' }) if defined $given && $given ne $p->{sha};
    # A value saved in a form from before 0.1.6 shows as saved (it reads as its new form), and
    # migrate shows the new form as written
    my $old = sub { return exists $_[0]{raw} && settings_write::old_form($_[0]{key}, $_[0]{raw}) ? jsonc::encode_bytes($_[0]{raw}) : $_[0]{old} };
    my $new = sub { return $sub eq 'migrate' && $_[0]{kind} eq 'set' ? $_[0]{json} : $_[0]{new} };
    my @ch = map { "  $_->{key}: " . $old->($_) . ' -> ' . $new->($_) . ($_->{kind} eq 'remove' ? ' (removed)' : '') } @{ $p->{changes} };
    my @notes = (settings_reset::notes($p), settings_write::clamp_notes($p));
    if (!$apply) {
        my $store = ctx::store_cmd();
        my $line = $sub ne 'reset' ? "to apply it: the same command with --plan $p->{sha} --apply"
            : 'to apply it: ' . (defined $store ? util::text($store) . ' ' : '') . 'settings reset '
              . (ref $want ? join(' ', map { $_->{key} } @{ $p->{changes} }) : '--all') . " --plan $p->{sha} --apply";
        args::out("settings $sub: dry run, nothing written · $ft · $where", map({ s/\A  /  would change /r } @ch), @ns, @kept, @notes, @extra, $line);
        return 0;
    }
    my $r = settings_write::apply($p);
    return _refused($sub, $p, $r) if $r->{state} ne 'done';
    my $head = $sub eq 'reset' ? 'removed ' . join(', ', map { $_->{key} } @{ $p->{changes} }) . " from $ft ($where)" : "changed $ft ($where)";
    args::out("settings $sub: $head", @ch, '  backup: ' . util::text(util::abbrev($r->{backup})) . ' (the file as it was)',
              @ns, @kept, @notes, @extra, _takes_effect());
    return 0;
}

exit(args::main(\&run, @ARGV));

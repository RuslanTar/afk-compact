# cmd/settings.pl: `settings show` and `settings reset` (0.1.2 visible defaults). Owner: WP-core.
#   settings show [--root D] [--log-dir D]
#       read-only: the settings file and the plugin's options key, then every key in @KEYS order
#       with its value, source and default, the warnings (a saved "", an ambiguous key), the
#       notes, and the user-run reset line.
#   settings reset <key>...|--all [--plan P] [--apply]
#       a dry run unless --apply (as `project copy`): the members it would remove with their
#       values and defaults (never a pattern's or a list's text), and the line to type, which
#       carries --plan (the file's hash) so the apply refuses a file changed since. The user runs
#       --apply (`!`); the skills relay that line and never run it. lib/settings_reset.pm.
# Exit codes: 0, 3 (refused: nothing written), 64 (usage), 70.
use strict;
use warnings;
use utf8;
require "settings_reset.pm";

package cmd_settings;

my $USAGE_RESET = 'usage: settings reset <key>...|--all [--apply]';

sub run {
    my $sub = shift @_;
    die "usage: settings show | settings reset <key>...|--all [--apply]\n" unless defined $sub && ($sub eq 'show' || $sub eq 'reset');
    my ($opt, $rest) = args::parse(\@_, bools => [qw(apply all)], known => [qw(plan root log-dir)]);
    rc::init(sid => undef, writer => 'helper', flags => settings::flags_from($opt));
    return show() if $sub eq 'show';
    die "$USAGE_RESET\n" if ($opt->{all} && @$rest) || (!$opt->{all} && !@$rest);
    for my $k (@$rest) { die "usage: settings reset: $k is no setting of this plugin\n" unless exists $settings::TYPE{$k} }
    return reset_cmd($opt->{all} ? 'all' : $rest, $opt->{plan}, $opt->{apply});
}

sub _file_text { return util::text(util::abbrev(settings::config_dir() . '/settings.json')) }

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
    push @out, 'reset (a dry run unless you add --apply; type it yourself): ! ' . util::text($store) . ' settings reset <key>...' if defined $store;
    args::out(@out);
    return 0;
}

my %REFUSED = (
    'not-json' => 'your settings.json is not plain JSON (comments, a trailing comma or a syntax error); edit it by hand or in /config',
    changed => 'your settings.json changed since the dry run; run the dry run again',
    verify => 'the edited text did not read back as your settings minus those keys; nothing written',
    'no-watch' => 'no log folder for the backup (see the root lines of /status)',
    'not-file' => 'your settings.json is not a regular file',
    'hard-link' => 'your settings.json has a second name (a hard link) and a reset writes a new file under one name only; edit it by hand or in /config',
    backup => 'no backup could be written',
);

sub _refused {
    my ($p, $why) = @_;
    my $t = $why eq 'ambiguous'
        ? 'several plugin option keys in your settings.json (' . join(', ', map { '"' . util::text($_) . '"' } @{ $p->{candidates} || [] })
          . '); remove the one no longer used, then run this again'
        : $why =~ /\A(?:splice:)?twice:(.*)\z/s ? 'your settings.json names "' . util::text($1) . '" twice in one object; edit it by hand or in /config'
        : $REFUSED{$why} // "refused ($why)";
    args::out("settings reset: refused, $t");
    return 3;
}

sub reset_cmd {
    my ($want, $given, $apply) = @_;
    my $p = settings_reset::plan($want);
    return _refused($p, $p->{why}) if $p->{state} eq 'refused';
    my $ft = _file_text();
    my $where = defined $p->{ckey} ? 'plugin options under "' . util::text($p->{ckey}) . '"' : '';
    my @kept = @{ $p->{kept} } ? ('  kept by --all (consent or protective; name one to reset it): ' . join(', ', @{ $p->{kept} })) : ();
    my @ns = @{ $p->{not_saved} } ? ('  not saved, nothing to remove: ' . join(', ', @{ $p->{not_saved} })) : ();
    if ($p->{state} eq 'nothing') {
        my $why = ($p->{why} // '') eq 'no-file' ? " (no $ft)" : ($p->{why} // '') eq 'no-options' ? " (no plugin options in $ft)" : '';
        args::out("settings reset: nothing to remove$why", @ns, @kept);
        return 0;
    }
    return _refused($p, 'changed') if defined $given && $given ne $p->{sha};
    my @rm = map { "  would remove $_ (now " . settings_reset::now_text($p, $_) . '; default '
                   . settings::show_value($_, settings::manifest_default($_)) . ')' } @{ $p->{remove} };
    my @notes = settings_reset::notes($p);
    if (!$apply) {
        my $store = ctx::store_cmd();
        my $args = ref $want ? join(' ', @{ $p->{remove} }) : '--all';
        args::out("settings reset: dry run, nothing written · $ft · $where", @rm, @ns, @kept, @notes,
                  defined $store ? 'to apply it, type: ! ' . util::text($store) . " settings reset $args --plan $p->{sha} --apply"
                                 : "to apply it, run the plugin's settings reset with --plan $p->{sha} --apply");
        return 0;
    }
    my $r = settings_reset::apply($p, rc::watch());
    return _refused($p, $r->{why}) if $r->{state} ne 'done';
    args::out('settings reset: removed ' . join(', ', @{ $p->{remove} }) . " from $ft ($where)",
              '  backup: ' . util::text(util::abbrev($r->{backup})), @ns, @kept, @notes,
              "  takes effect: the plugin's helper reads the new values at its next call; Claude Code passes them to the hooks once it "
              . 'reads its settings again (whether a running session does that by itself is not checked yet: restart Claude Code to be sure)');
    return 0;
}

exit(args::main(\&run, @ARGV));

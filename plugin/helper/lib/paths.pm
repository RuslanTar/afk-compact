package paths;
# lib/paths.pm: where things live (MOD-SPEC conventions). Owner: WP-core.
# paths::for(settings, sid) -> {root, watch, disposable, watch_default}
use strict;
use warnings;
use utf8;

sub for {
    my ($settings, $sid) = @_;
    my $v = ref $settings eq 'HASH' && $settings->{values} ? $settings->{values} : $settings;
    my $root = util::clean_path($v->{handoff_root});
    my $watch = (defined $v->{log_dir} && $v->{log_dir} ne '') ? util::clean_path($v->{log_dir}) : "$root/.watch";
    my $disp = util::clean_path($v->{disposable_root});
    my $udef = ctx::user_config();
    my $droot = ref $udef->{handoff_root} eq 'HASH' ? $udef->{handoff_root}{default} : '~/.claude/handoffs';
    my $wdef = util::clean_path($droot // '~/.claude/handoffs') . '/.watch';
    return { root => $root, watch => $watch, disposable => $disp, watch_default => $wdef };
}

sub sid_dir { my ($p, $sid) = @_; return "$p->{watch}/$sid" }

1;

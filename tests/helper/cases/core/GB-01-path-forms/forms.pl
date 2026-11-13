# GB-01: util::root_form and util::posix_form (the staged copy, -I<plugin>/helper/lib) over drive,
# MSYS, UNC and non-ASCII paths, each given as bytes and, where it says so, as a UTF8-flagged
# character string. One line per call: <sub> <label> (<input form>): <result> (<result form>).
use strict;
use warnings;
$| = 1;
binmode STDOUT;
require "util.pm";

my @rows = (
    ['drive',               'C:/w/x',                    'bytes', 'chars'],
    ['drive-backslash',     'C:\\w\\x',                  'bytes'],
    ['msys',                '/c/w/x',                    'bytes'],
    ['unc',                 '//srv/share/x',             'bytes'],
    ['unc-backslash',       '\\\\srv\\share\\x',         'bytes'],
    ['drive-relative',      'C:x',                       'bytes'],
    ['relative',            'w/x',                       'bytes'],
    ['non-ascii',           "C:/w/r\xc3\xabpo",          'bytes', 'chars'],
    ['non-ascii-backslash', "C:\\w\\r\xc3\xabpo\\sub",   'bytes', 'chars'],
    ['non-ascii-first',     "C:/r\xc3\xabpo/x",          'chars'],
    ['non-ascii-trailing',  "C:/w/r\xc3\xabpo/",         'bytes'],
);
for my $r (@rows) {
    my ($label, $raw, @forms) = @$r;
    for my $form (@forms) {
        my $p = $raw;
        if ($form eq 'chars') { utf8::decode($p); utf8::upgrade($p) }
        for my $fn (qw(root_form posix_form)) {
            my $sub = util->can($fn);
            if (!$sub) { print "$fn $label ($form): no such sub\n"; next }
            my $q = $sub->($p);
            my $kind = !defined $q ? '-' : utf8::is_utf8($q) ? 'chars' : 'bytes';
            my $out = defined $q ? $q : 'undef';
            utf8::encode($out) if utf8::is_utf8($out);
            print "$fn $label ($form): $out ($kind)\n";
        }
    }
}

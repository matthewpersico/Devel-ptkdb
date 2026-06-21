#!perl

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Find;

# The non eval version calls use_ok() in a BEGIN statement, but Test::Pod sets
# the number of tests to the number of files being tested, and the use_ok()
# adds one more test, which confuses Test::More.
eval q(use Perl::Tidy);    ## no critic (BuiltinFunctions::ProhibitStringyEval)
plan skip_all => "Perl::Tidy required for testing code tidiness" if $@;

sub is_perl_code {
    # Match by name
    if ($_[0] =~ m/\.(p[ml]|t|PL)/) {
        return 1;
    }
    open my $fh, '<', $_[0]
        or do {
        diag("MANIFEST file entry '$_[0]' not found.");
        return 0;
        };
    my $text = <$fh>;
    if ($text && $text =~ m/#!.*perl/) {
        return 1;
    }
    return 0;
}

open my $fh, '<', "$FindBin::Bin/../MANIFEST";
my @files = map {
    my $filename = "$FindBin::Bin/../$_";
    chomp $filename;
    $filename =~ s/\s+.*//;
    $filename;
} <$fh>;
close $fh;

my @perl_files = grep { is_perl_code($_) } @files;
my @tidy_files = map  {"${_}.tdy"} @perl_files;
push @tidy_files, map { my $x = $_; $x =~ s|/lib/|/blib/lib/|; $x } grep {m|/lib/|} @tidy_files;
# In case there were left overs from the last run.
unlink @tidy_files;
my $argv = join(
    ' ',
    "--pro=$FindBin::Bin/../.perltidyrc", '--assert-tidy',
    '-nst',    # Turns off the -st in -pbp in perltidyrc
    @perl_files
);
if (is(Perl::Tidy::perltidy(argv => $argv), 0, "tidy")) {
    unlink @tidy_files;
}
done_testing();

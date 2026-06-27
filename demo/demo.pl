#!/usr/bin/env perl

use 5.16.3;
use warnings;

use DateTime;

my @a;
my $date  = DateTime->now();
my $h     = { 43, 23 };
my $dummy = 6;

sub dummystuff {
    my $a = $_[0];
    push @$a, 4;
    push @$a, 5;
    push @$a, 6;
    push @$a, 7;
    push @$a, 8;
    push @$a, 9;
    push @$a, 10;
    push @$a, 11;
    push @$a, 12;
    push @$a, 13;
    push @$a, 14;
    push @$a, 15;
}

my %h = (
    date => $date,
    hash => $h,
    scl  => \$dummy
);
$dummy = 42;

dummystuff(\@a);

for (0 .. 15) {
    push @a, \%h;
}

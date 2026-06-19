#!/usr/bin/env perl

use 5.16.3;
use warnings;

use DateTime;

my $date  = DateTime->now();
my $h     = { 43, 23 };
my $dummy = 6;

sub dummystuff {

    my @a = (4);
    push @a, 5;
    push @a, 6;
    push @a, 7;
    push @a, 8;
    push @a, 9;
    push @a, 10;
    push @a, 11;
    push @a, 12;
    push @a, 13;
    push @a, 14;
    push @a, 15;
}

my %h = (
    date => $date,
    hash => $h,
    scl  => \$dummy
);
$dummy = 42;

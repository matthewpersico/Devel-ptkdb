#!/usr/bin/env perl

use 5.16.3;
use warnings;

use DateTime;

my $date  = DateTime->now();
my $h     = { 43, 23 };
my $dummy = 6;
my %h     = (
    date => $date,
    hash => $h,
    scl  => \$dummy
);
$dummy = 42;

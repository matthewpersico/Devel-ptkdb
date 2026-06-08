#!perl

use strict;
use warnings;
use Test::More;

# The non eval version calls use_ok() in a BEGIN statement, but Test::Pod sets
# the number of tests to the number of files being tested, and the use_ok()
# adds one more test, which confuses Test::More.
eval q(use Test::Perl::Critic);    ## no critic (BuiltinFunctions::ProhibitStringyEval)
plan skip_all => "Test::Perl::Critic required for testing PBP compliance" if $@;
Test::Perl::Critic::all_critic_ok();

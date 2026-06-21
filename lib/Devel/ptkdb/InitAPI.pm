package Devel::ptkdb::InitAPI;

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Core and CPAN modules
use Config;

# ===========================================================================
# Project modules
# None

# ===========================================================================
# Shareable package data
# None

# ===========================================================================
# Package data
# None

# ===========================================================================
# Package methods

sub debug_say {
    goto &Devel::ptkdb::debug_say;
}

sub brkpt {
    my ($fname, @idx) = @_;

    debug_say(
        msg    => 'made it to bkrpt()',
        action => 'trace',
        dump   => {
            descr => 'args',
            ref   => [$fname, @idx]
        }
    );
    my $offset    = DB::debugger_injected_line_offset($fname);
    my $ptkdb_obj = Devel::ptkdb::obj();

    for (@idx) {
        if (!&DB::is_line_breakable($fname, $_ + $offset)) {
            my ($package, $filename, $line) = caller;
            print "$filename:$line:  $fname line $_ is not breakable\n";
            next;
        }
        $ptkdb_obj->insertBreakpoint($fname, $_, 1);    # insert a simple breakpoint
    }
}

sub condbrkpt {
    my ($fname)   = shift;
    my $offset    = DB::debugger_injected_line_offset($fname);
    my $ptkdb_obj = Devel::ptkdb::obj();

    while (@_) {    # arg loop
        my ($index, $expr) = splice @_, 0, 2;    # take args 2 at a time

        if (!&DB::is_line_breakable($fname, $index + $offset)) {
            my ($package, $filename, $line) = caller;
            print "$filename:$line:  $fname line $index is not breakable\n";
            next;
        }
        $ptkdb_obj->insertBreakpoint($fname, $index, 1, $expr);    # insert a simple breakpoint
    }

}

sub brkonsub {
    my (@names) = @_;
    my $ptkdb_obj = Devel::ptkdb::obj();

    for (@names) {

        # get the filename and line number range of the target subroutine

        if (!exists $DB::sub{$_}) {
            print "No subroutine $_.  Try main::$_\n";
            next;
        }

        $DB::sub{$_} =~ /(.*):([0-9]+)-([0-9]+)$/o;    # file name will be in $1, start line $2, end line $3

        for ($2 .. $3) {
            next unless &DB::is_line_breakable($1, $_);
            $ptkdb_obj->insertBreakpoint($1, $_, 1);
            last;                                      # only need the one breakpoint
        }
    }

}

sub brkonsub_regex {
    my (@regexps) = @_;
    my @subList;

    #
    # accumulate matching subroutines
    #
    for my $regexp (@regexps) {
        study $regexp;
        push @subList, grep /$regexp/, keys %DB::sub;
    }

    brkonsub(@subList);    # set breakpoints on matching subroutines

}

sub textTagConfigure {
    my ($tag, @config) = @_;
    my $ptkdb_obj = Devel::ptkdb::obj();

    $ptkdb_obj->{'text'}->tagConfigure($tag, @config);

}

sub add_exprs {
    my $ptkdb_obj = Devel::ptkdb::obj();
    push @{ $ptkdb_obj->{'expr_list'} },
        map { 'expr' => $_, 'depth' => $ptkdb_obj->{'expr_depth'} }, @_;
}

# ===================================================================
# These appear to be part of the use ptkdbrc API, but not documented.
sub setTabs {
    my $ptkdb_obj = Devel::ptkdb::obj();

    $ptkdb_obj->{'text'}->configure(-tabs => [@_]);

}

# Register a subroutine reference that will be called whenever ptkdb sets up
# its windows.
sub register_user_window_init {
    my $ptkdb_obj = Devel::ptkdb::obj();
    push @{ $ptkdb_obj->{'user_window_init_list'} }, @_;
}

# Register a subroutine reference that will be called whenever ptkdb enters
# from code.
sub register_user_DB_entry {
    my $ptkdb_obj = Devel::ptkdb::obj();
    push @{ $ptkdb_obj->{'user_window_DB_entry_list'} }, @_;
}

sub get_notebook_widget {
    my $ptkdb_obj = Devel::ptkdb::obj();
    return $ptkdb_obj->{'notebook'};
}

1;

## no critic (Modules::RequireFilenameMatchesPackage)
package DB;

# Pragmas
use strict;
use warnings;

# Core and CPAN modules
use Carp;

# Project modules
## None

# Package Data
my %PD = (
    brkpt_search_line_count => 20,
    brkpt_fixed_msg         => [],
);

## ===========================================================================
## Useful aliases

sub ddn {
    goto &Data::Dumper::new;
}

sub ddd {
    goto &Data::Dumper::Dump;
}

## ===========================================================================
## Devel::ptkdb access
sub console_say {
    goto &Devel::ptkdb::console_say;
}

sub console_string {
    goto &Devel::ptkdb::console_string;
}

sub debug_say {
    goto &Devel::ptkdb::debug_say;
}

sub debug_dump {
    goto &Devel::ptkdb::debug_dump;
}

## ===========================================================================
## dbline handlers
sub _dbline_key {
    my ($fname) = @_;
    return unless defined $fname && length $fname;

    $fname =~ s/^_<//;    # tolerate old saved state files temporarily
    return '_<' . $fname;
}

sub _dbline_glob {
    my ($fname) = @_;

    my $key = _dbline_key($fname);
    return unless defined $key;
    return unless exists $main::{$key};

    return $main::{$key};
}

sub _dbline_array {
    my ($fname) = @_;

    my $glob = _dbline_glob($fname);
    return unless $glob;

    return *{$glob}{ARRAY};
}

sub _dbline_hash {
    my ($fname) = @_;

    my $glob = _dbline_glob($fname);
    return unless $glob;

    return *{$glob}{HASH};
}

sub debugger_injected_line_offset {
    my ($fname) = @_;

    my $lines = _dbline_array($fname);
    return 0 unless $lines;

    ## Yes, we are checking for the debugger injecting itself on the first line
    ## of the code, which is typically the zeroth [0] element.  But not in the
    ## debugger. Apparently the zeroth element of *dbline goes
    ## unused. <facepalm>.
    my $diio = defined $lines->[1] && $lines->[1] =~ /use\s+.*Devel::_?ptkdb/ ? 1 : 0;
    if ($diio) {
        debug_say(
            msg    => "Offset adjusted!",
            action => 'trace'
        );
    }
    return $diio;
}

sub is_line_breakable {
    my ($fname, $lineno) = @_;

    my $lines = _dbline_array($fname);
    return 0 unless $lines;

    return (0 + $lines->[$lineno]) != 0;
}

sub set_breakpoint {
    my ($fname, $lineno, $value) = @_;

    my $breakpoints = _dbline_hash($fname);
    return 0 unless $breakpoints;

    $breakpoints->{$lineno} = $value;
    return 1;
}

sub get_breakpoint {
    my ($fname, $lineno) = @_;

    my $breakpoints = _dbline_hash($fname);
    return unless $breakpoints;

    return $breakpoints->{$lineno};
}

sub get_breakpoints {
    my ($fname) = @_;

    my $breakpoints = _dbline_hash($fname);
    return values %{$breakpoints};
}

sub get_code_line {
    my ($fname, $lineno) = @_;

    my $lines = _dbline_array($fname);
    return unless $lines;

    return $lines->[$lineno];
}

sub get_code_lines {
    my ($fname) = @_;
    return _dbline_array($fname);
}

sub clear_breakpoint_info {
    my ($fname, $lineno, $clearsub) = @_;

    my $breakpoints = _dbline_hash($fname);
    return unless $breakpoints;

    my $value = delete $breakpoints->{$lineno};

    $clearsub->($value) if $value && $clearsub;

    return $value;
}

sub clear_all_breakpoint_info {
    my ($clearsub) = @_;

    while (my ($key, $value) = each %main::) {
        next unless $key =~ /^_</;

        my $fname = $key;
        $fname =~ s/^_<//;

        my $breakpoints = _dbline_hash($fname);
        next unless $breakpoints;

        for my $dbkey (keys %{$breakpoints}) {
            my $brkpt = delete $breakpoints->{$dbkey};
            next unless $brkpt && $clearsub;

            $clearsub->($brkpt);
        }
    }

    return;
}

sub get_breakpoint_indexes {
    my ($fname) = @_;

    my $breakpoints = _dbline_hash($fname);
    return unless $breakpoints;

    return keys %{$breakpoints};
}

## ===========================================================================
## breakpoint handlers

# When we restore breakpoints from a state file, they've often 'moved' because
# the file has been editted. We try to restore to the original position as
# follows:

# - Start at the original line number.

# - If no match, search backwards no more than $PD{brkpt_search_line_count}
#   lines.

# - If no match, start at the original line plus one, and search forward no
#   more than $PD{brkpt_search_line_count} lines.

# If there's no exact match after all that, then we try to rewrite the
# breakpoint as close as possible to the old line location taking into account
# unbreakable lines.

sub fix_breakpoints {
    my (%args) = (
        fname  => q(),    # The code file we are examining
        offset => 0,      # Used to avoid
        brkpts => [],
        lines  => [],
        @_
    );

    my ($startLine, $endLine, $nLines, $found);
    my (@retList);

    $nLines = @{ $args{lines} };
    $PD{brkpt_fixed_msg} = [];
    BREAKPOINTS:
    foreach my $brkpt (@{ $args{brkpts} }) {
        $found = 0;

        debug_dump(
            action => 'skip',
            dump   => [
                {   descr => '$brkpt->{text}',
                    ref   => $brkpt->{text}
                },
                {   descr => '$brkpt->{line}',
                    ref   => $brkpt->{line},
                },
                {   descr => '$args{lines}->[$brkpt->{line}]',
                    ref   => $args{lines}->[$brkpt->{line}]
                },
            ]
        );

        # We compare code lines sans whitespace to help match in the face of
        # perl tidying.
        my $code_text = '';
        if (defined $args{lines}->[$brkpt->{line}]) {
            $code_text = $args{lines}->[$brkpt->{line}];
            $code_text =~ s/\s+//g;
        }
        my $brkpt_text = $brkpt->{text};
        $brkpt->{text} =~ s/\s+//g;
        if ($brkpt_text eq $code_text) {
            $found = 1;
            push @retList, $brkpt;
            next BREAKPOINTS;
        }

        my $pivot;
        # Look for the same line nearby
        if (not $found) {
            $startLine = $brkpt->{line} - $PD{brkpt_search_line_count};
            $startLine = 0 if ($startLine < 0);
            $endLine   = $brkpt->{line} + $PD{brkpt_search_line_count};
            $endLine   = $nLines - 1 if $endLine > $nLines;
            $pivot     = int(($endLine - $startLine) / 2);

            debug_dump(
                action => 'skip',
                dump   => [
                    {   descr => 'startLine',
                        ref   => $startLine
                    },
                    {   descr => 'endLine',
                        ref   => $endLine
                    },
                    {   descr => '$brkpt->{line}',
                        ref   => $brkpt->{line}
                    },
                    {   descr => '$pivot',
                        ref   => $pivot
                    },
                ]
            );
            NEARBY_SEARCH:
            for ((reverse $startLine .. $pivot), $pivot + 1 .. $endLine) {
                $code_text = $args{lines}->[$_];
                $code_text =~ s/\s+//g;
                $brkpt_text = $brkpt->{text};
                $brkpt->{text} =~ s/\s+//g;
                next unless $brkpt_text eq $code_text;
                push @{ $PD{brkpt_fixed_msg} },
                    (
                    "Breakpoint $args{fname} (line $brkpt->{line}) was moved",
                    " to line $_ because the statement moved.",
                    q()
                    );
                $brkpt->{line} = $_;
                push @retList, $brkpt;
                $found = 1;
                last NEARBY_SEARCH;
            }
        }

        # Try and break beforehand. Afterward may be too late.
        if (not $found) {
            PRIOR_POSITION: for ((reverse $startLine .. $pivot - 1)) {
                my $brkpt_line = $_ + $args{offset};
                if (DB::is_line_breakable($args{fname}, $brkpt_line)) {
                    my ($from, $to) = ($brkpt->{text}, $args{lines}->[$brkpt_line]);
                    chomp $from;
                    chomp $to;
                    push @{ $args{brkpt_fixed_msg} },
                        (
                        "Breakpoint $args{fname} (line $brkpt->{line}) was moved",
                        " from [$from]",
                        " to [$to] (line $_)",
                        " because the original statement cannot be found.",
                        q()
                        );
                    $brkpt->{line} = $_;
                    $brkpt->{text} = $args{lines}->[$_];
                    push @retList, $brkpt;
                    $found = 1;
                    last PRIOR_POSITION;
                }
            }
        }

        # Oh well...
        if (not $found) {
            my $text = $brkpt->{text};
            chomp $text;
            push @{ $args{brkpt_fixed_msg} },
                (
                "Breakpoint $args{fname} (line $brkpt->{line})",
                " for statement [$text]",
                " is lost due to code changes.",
                q()
                );
        }
    }
    scalar(@{ $PD{brkpt_fixed_msg} }) && console_say($PD{brkpt_fixed_msg});
    return @retList;
}

sub breakpoints_to_save {
    my $brkList = {};

    for my $key (keys %main::) {
        next unless $key =~ /^_</;

        my $fname = $key;
        $fname =~ s/^_<//;

        my $breakpoints = _dbline_hash($fname);
        next unless $breakpoints;

        my @breaks = values %{$breakpoints};
        next unless @breaks;

        my $list = [];

        for my $brkpt (@breaks) {
            push @{$list}, { %{$brkpt} };
        }

        $brkList->{$fname} = $list;
    }

    return $brkList;
}

sub restore_breakpoints_from_save {
    my ($brkpt_list) = @_;
    my ($fname, $list, $brkpt, @newList);

    # $fname is the code where breakpoints are set and $list is the list of
    # breakpoints in that code.
    while (my ($fname, $list) = each %{$brkpt_list}) {
        my $lines = _dbline_array($fname);
        debug_dump(
            action => 'skip',
            msg    => 'Checking for adjusting the offset from 0 to 1.',
            dump   => [
                {   descr => "\$lines of $fname",
                    ref   => $lines
                }
            ]
        );
        my $breakpoints = _dbline_hash($fname);
        next unless $lines && $breakpoints;

        my $offset = debugger_injected_line_offset();

        my @newList = fix_breakpoints(
            fname  => $fname,
            offset => $offset,
            brkpts => $list,
            lines  => $lines
        );

        for my $brkpt (@newList) {
            if (!DB::is_line_breakable($fname, $brkpt->{line} + $offset)) {
                console_say("Breakpoint $fname:$brkpt->{line} in config file is not breakable.");
                next;
            }
            $breakpoints->{ $brkpt->{line} } = { %{$brkpt} };
        }
    }

    return;
}

## ===========================================================================
## state handlers
sub breakpoint_state {
    return DB::breakpoints_to_save();
}

sub restore_breakpoint_state {
    my ($files) = @_;
    return unless $files;
    DB::restore_breakpoints_from_save($files);
}

# =========================================================================
# Below here is code that existed prior to the re-architecting of
# 2026/June. Any function that can be used untouched, or is edited to be used,
# will be hoisted up above.

# Here's the clue...
# eval only seems to eval the context of
# the executing script while in the DB
# package.  When we had updateExprs in the Devel::ptkdb
# package eval would turn up an undef result.
sub updateExprs {
    my ($package) = @_;
    my $window = Devel::ptkdb::window();

    #
    # Update expressions
    #
    $window->deleteAllExprs();
    my (@result);

    for my $expr (@{ $window->{'expr_list'} }) {
        next if length $expr == 0;

        @result = &DB::dbeval($package, $expr->{'expr'});

        if (@result == 1) {
            $window->insertExpr(
                [$result[0]],
                $window->{'data_list'},
                $result[0], $expr->{'expr'}, $expr->{'depth'}
            );
        } else {
            $window->insertExpr(
                [\@result],
                $window->{'data_list'},
                \@result, $expr->{'expr'}, $expr->{'depth'}
            );
        }
    }

}

sub dbint_handler {
    my ($sigName) = @_;
    $DB::single = 1;
    print "signalled\n";
}

#
# Do first time initialization at the startup
# of DB::DB
#
sub Initialize {
    my ($fName) = @_;
    return if $DB::ptkdb::isInitialized;
    $DB::ptkdb::isInitialized = 1;

    my $window = Devel::ptkdb::window();
    return unless defined $window;

    $window->do_user_init_files();

    $DB::dbint_handler_save = $SIG{'INT'}         unless $DB::sigint_disable;    # saves the old handler
    $SIG{'INT'}             = "DB::dbint_handler" unless $DB::sigint_disable;

    # Check for a 'restart' file

    if ($ENV{'PTKDB_RESTART_STATE_FILE'}
        && -e $ENV{'PTKDB_RESTART_STATE_FILE'}) {
        #
        # Restore expressions and breakpoints in state file
        #
        print "restoring state from $ENV{'PTKDB_RESTART_STATE_FILE'}\n";
        $window->restore_state_file($ENV{'PTKDB_RESTART_STATE_FILE'});
        unlink $ENV{'PTKDB_RESTART_STATE_FILE'};    # delete state file
        $ENV{'PTKDB_RESTART_STATE_FILE'} = "";      # clear entry
    } else {
        $window->restore_state_file();              # look for a default based on $0
    }

}

sub restoreState {
    my ($fname) = @_;
    my $window = Devel::ptkdb::window();
    return $window->restore_state_file($fname);
}

sub save_state_file {
    my ($fname) = @_;
    my $window = Devel::ptkdb::window();
    return $window->save_state_file($fname);
}

sub SetStepOverBreakPoint {
    my ($offset) = @_;
    $DB::step_over_depth = $DB::subroutine_depth + ($offset ? $offset : 0);
}

#
# NOTE:   It may be logical and somewhat more economical
#         lines of codewise to set $DB::step_over_depth_saved
#         when we enter the subroutine, but this gets called
#         for EVERY callable line of code in a program that
#         is being debugged, so we try to save every line of
#         execution that we can.
#
sub isBreakPoint {
    my ($fname, $line, $package) = @_;
    my ($brkpt);

    if (   $DB::single
        && ($DB::step_over_depth < $DB::subroutine_depth)
        && ($DB::step_over_depth > 0)
        && !$DB::on) {
        $DB::single = 0;
        return 0;
    }
    #
    # doing a step over/in
    #

    if ($DB::single || $DB::signal) {
        $DB::single           = 0;
        $DB::signal           = 0;
        $DB::subroutine_depth = $DB::subroutine_depth;
        return 1;
    }
    #
    # 1st Check to see if there is even a breakpoint there.
    # 2nd If there is a breakpoint check to see if it's check box control is 'on'
    # 3rd If there is any kind of expression, evaluate it and see if it's true.
    #
    $brkpt = &DB::get_breakpoint($fname, $line);

    return 0 if (!$brkpt || !$brkpt->{'value'} || !breakPointEvalExpr($brkpt, $package));

    &DB::clear_breakpoint_info($fname, $line) if ($brkpt->{'type'} eq 'temp');

    $DB::subroutine_depth = $DB::subroutine_depth;

    return 1;
}

#
# Check the breakpoint expression to see if it
# is true.
#
sub breakPointEvalExpr {
    my ($brkpt, $package) = @_;
    my (@result);

    return 1 unless $brkpt->{expr};    # return if there is no expression

    no strict;                         ## no critic TestingAndDebugging::ProhibitNoStrict

    @result = &DB::dbeval($package, $brkpt->{'expr'});

    use strict;
    my $window = Devel::ptkdb::window();

    $window->DoAlert($@) if $@;

    return ($result[0] or @result);    # we could have a case where the 1st
                                       # element is undefined but subsequent
                                       # elements are defined

}

#
# Evaluate the given expression, return the result.
# MUST BE CALLED from within DB::DB in order for it
# to properly interpret the vars
#
sub dbeval {
    my ($ptkdb__package, $ptkdb__expr) = @_;
    my (@ptkdb__result, $ptkdb__str);
    my (@ptkdb_args);

    no strict;    ## no critic TestingAndDebugging::ProhibitNoStrict
                  #
                  # This substitution is done so that
                  # we return HASH, as opposed to an ARRAY.
                  # An expression of %hash results in a
                  # list of key/value pairs.
                  #

    $ptkdb__expr =~ s/^\s*%/\\%/o;

    @_ = @DB::saved_args;    # replace @_ arg array with what we came in with

    @ptkdb__result = eval <<__EVAL__;    ## no critic TestingAndDebugging::ProhibitNoStrict


  \$\@ = \$DB::save_err ;

  package $ptkdb__package ;

  $ptkdb__expr ;

__EVAL__

    @ptkdb__result = ("ERROR ($@)") if $@;

    use strict;

    return @ptkdb__result;
}

#
# Call back we give to our 'quit' button
# and binding to the WM_DELETE_WINDOW protocol
# to quit the debugger.
#
sub dbexit {
    exit;
}

#
# This is the primary entry point for the debugger.  When a perl program
# is parsed with the -d(in our case -d:ptkdb) option set the parser will
# insert a call to DB::DB in front of every excecutable statement.
#
# Refs:  Progamming Perl 2nd Edition, Larry Wall, O'Reilly & Associates, Chapter 8
#

{
    no warnings 'redefine';

    # Keep emacs imenu happy
    #<<< perltidy
sub DB {
    #>>> perltidy
        @DB::saved_args = @_;    # save arg context
        $DB::save_err   = $@;    # save value of $@
        my ($package, $filename, $line) = caller;
        my ($stop, $cnt);

        unless ($DB::ptkdb::isInitialized) {
            return if ($filename ne $0);    # not in our target file
            &DB::Initialize($filename);
        }

        if (!isBreakPoint($filename, $line, $package)) {
            $DB::single = 0;
            $@          = $DB::save_err;
            return;
        }

        my $window = Devel::ptkdb::window();
        if (!$window) {    # not setup yet
            $@ = $DB::save_err;
            return;
        }

        $window->setup_main_window() unless $window->{'main_window'};

        $window->EnterActions();

        my ($saveP);
        $saveP = $^P;
        $^P    = 0;

        $DB::on = 1;

        #
        # The user can specify this variable in one of the startup files,
        # this will make the debugger run right after startup without
        # the user having to press the 'run' button.
        #
        if ($DB::no_stop_at_start) {
            $DB::no_stop_at_start = 0;
            $DB::on               = 0;
            $@                    = $DB::save_err;
            return;
        }

        if (!$DB::sigint_disable) {
            $SIG{'INT'} = $DB::dbint_handler_save if $DB::dbint_handler_save;    # restore original signal handler
            $SIG{'INT'} = "DB::dbexit" unless $DB::dbint_handler_save;
        }

        #$window->{main_window}->raise() ; # bring us to the top make sure OUR event loop runs
        $window->{main_window}->focus();

        $window->set_file($filename, $line);
        #
        # Refresh the exprs to see if anything has changed
        #
        updateExprs($package);

        #
        # Update subs Page if necessary
        #
        $cnt = scalar keys %DB::sub;
        if ($cnt != $window->{'subs_list_cnt'} && $window->{'subs_page_activated'}) {
            $window->fill_subs_page();
            $window->{'subs_list_cnt'} = $cnt;
        }
        #
        # Update the subroutine stack menu
        #
        $window->refresh_stack_menu();

        $window->{run_flag} = 1;

        my ($evt, @result, $r);

        for (;;) {
            #
            # we wait here for something to do
            #
            $evt = $window->main_loop();

            last if ($evt eq 'step');

            $DB::single = 0 if ($evt eq 'run');

            if ($evt eq 'balloon_eval') {
                $window->code_motion_eval(&DB::dbeval($package, $window->{'balloon_expr'}));
                next;
            }

            if ($evt eq 'qexpr') {
                my $str;
                @result = &DB::dbeval($package, $window->{'qexpr'});
                $window->{'quick_entry'}->delete(0, 'end');    # clear old text
                if (exists $window->{'quick_dumper'}) {
                    $window->{'quick_dumper'}->Reset();
                    $window->{'quick_dumper'}->Values([$#result == 0 ? @result : \@result]);
                    if ($window->{'quick_dumper'}->can('Dumpxs')) {
                        $str = $window->{'quick_dumper'}->Dumpxs();
                    } else {
                        $str = $window->{'quick_dumper'}->Dump();
                    }
                } else {
                    $str = "@result";
                }
                $window->{'quick_entry'}->insert(0, $str);             #enter the text
                $window->{'quick_entry'}->selectionRange(0, 'end');    # select it
                $evt = 'update';                                       # force an update on the expressions
            }

            if ($evt eq 'expr') {
                #
                # Append the new expression to the list
                # but first check to make sure that we don't
                # already have it.
                #

                if (grep $_->{'expr'} eq $window->{'expr'}, @{ $window->{'expr_list'} }) {
                    $window->DoAlert("$window->{'expr'} is already listed");
                    next;
                }

                @result = &DB::dbeval($package, $window->{expr});

                if (@result == 1) {
                    $r = $window->insertExpr(
                        [$result[0]],
                        $window->{'data_list'},
                        $result[0], $window->{'expr'}, $Devel::ptkdb::expr_depth
                    );
                } else {
                    $r = $window->insertExpr(
                        [\@result],
                        $window->{'data_list'},
                        \@result, $window->{'expr'}, $Devel::ptkdb::expr_depth
                    );
                }

                #
                # $r will be 1 if the expression was added succesfully, 0 if not,
                # and it if wasn't added sucessfully it won't be reevalled the
                # next time through.
                #
                push @{ $window->{'expr_list'} },
                    { 'expr' => $window->{'expr'}, 'depth' => $Devel::ptkdb::expr_depth }
                    if $r;

                next;
            }
            if ($evt eq 'update') {
                updateExprs($package);
                next;
            }
            if ($evt eq 'reeval') {
                #
                # Reevaluate the contents of the expression eval window
                #
                my $txt    = $window->{'eval_text'}->get('0.0', 'end');
                my @result = &DB::dbeval($package, $txt);

                $window->updateEvalWindow(@result);

                next;
            }
            last;
        }
        $^P = $saveP;
        $SIG{'INT'} = "DB::dbint_handler" unless $DB::sigint_disable;    # set our signal handler

        $window->LeaveActions();

        $@      = $DB::save_err;
        $DB::on = 0;
    }
}

#
# This is another place where we'll try and keep the code as 'lite' as possible
# to prevent the debugger from slowing down the user's application.
#
# When a perl program is parsed with the -d(in our case a -d:ptkdb) option the
# parser will route all subroutine calls through here, setting $DB::sub to the
# name of the subroutine to be called, leaving it to the debugger to make the
# actual subroutine call and do any pre or post processing it may need to do.
# In our case we take the opportunity to track the depth of the call stack so
# that we can update our 'Stack' menu when we stop.
#
# Refs:  Progamming Perl 2nd Edition, Larry Wall, O'Reilly & Associates, Chapter 8
#
#
sub sub {
    my ($result, @result);
    #
    # See NOTES(1)
    #
    $DB::subroutine_depth += 1 unless $DB::on;
    $DB::single = 0
        if (($DB::step_over_depth < $DB::subroutine_depth)
        && ($DB::step_over_depth >= 0)
        && !$DB::on);

    if (wantarray) {
        #
        # array context
        #
        # otherwise perl gripes about calling the sub by the reference
        no strict;              ## no critic TestingAndDebugging::ProhibitNoStrict
        @result = &$DB::sub;    # call the subroutine by name
        use strict;

        $DB::subroutine_depth -= 1 unless $DB::on;
        $DB::single = 1 if ($DB::step_over_depth >= $DB::subroutine_depth && !$DB::on);
        return @result;
    } elsif (defined wantarray) {

        #
        # scalar context
        #
        no strict;    ## no critic TestingAndDebugging::ProhibitNoStrict
        $result = &$DB::sub;
        use strict;

        $DB::subroutine_depth -= 1 unless $DB::on;
        $DB::single = 1 if ($DB::step_over_depth >= $DB::subroutine_depth && !$DB::on);
        return $result;
    } else {
        #
        # void context
        #

        no strict;    ## no critic TestingAndDebugging::ProhibitNoStrict
        &$DB::sub;
        use strict;

        $DB::subroutine_depth -= 1 unless $DB::on;
        $DB::single = 1 if ($DB::step_over_depth >= $DB::subroutine_depth && !$DB::on);
        return $result;

        return;
    }

}

1;    # return true value

=head1 NAME

Devel::ptkdb - Perl debugger using a Tk GUI

=head1 DESCRIPTION

  ptkdb is a debugger for perl that uses perlTk for a user interface.
  Features include:

    Hot Variable Inspection
    Breakpoint Control Panel
    Expression List
    Subroutine Tree


=begin html

    <body bgcolor=white>

=end html

=head1 SYNOPSIS

To debug a script using ptkdb invoke perl like this:

    perl -d:ptkdb myscript.pl

=head1 Usage

    perl -d:ptkdb myscript.pl

=head1 Code Pane

=over 4

=item Line Numbers

 Line numbers are presented on the left side of the window. Lines that
 have lines through them are not breakable. Lines that are plain text
 are breakable. Clicking on these line numbers will insert a
 breakpoint on that line and change the line number color to
 $ENV{'PTKDB_BRKPT_COLOR'} (Defaults to Red). Clicking on the number
 again will remove the breakpoint.  If you disable the breakpoint with
 the controls on the BrkPt notebook page the color will change to
 $ENV{'PTKDB_DISABLEDBRKPT_COLOR'}(Defaults to Green).

=item Cursor Motion

If you place the cursor over a variable (i.e. $myVar, @myVar, or
%myVar) and pause for a second the debugger will evaluate the current
value of the variable and pop a balloon up with the evaluated
result. I<This feature is not available with Tk400.>

If Data::Dumper(standard with perl5.00502)is available it will be used
to format the result.  If there is an active selection, the text of
that selection will be evaluated.

=back

=head1 Notebook Pane

=over 2

=item Exprs

 This is a list of expressions that are evaluated each time the
 debugger stops. The results of the expresssion are presented
 heirarchically for expression that result in hashes or lists.  Double
 clicking on such an expression will cause it to collapse; double
 clicking again will cause the expression to expand. Expressions are
 entered through B<Enter Expr> entry, or by Alt-E when text is
 selected in the code pane.

 The B<Quick Expr> entry, will take an expression, evaluate it, and
 replace the entries contents with the result.  The result is also
 transfered to the 'clipboard' for pasting.

=item Subs

 Displays a list of all the packages invoked with the script
 heirarchially. At the bottom of the heirarchy are the subroutines
 within the packages.  Double click on a package to expand
 it. Subroutines are listed by their full package names.

=item BrkPts

 Presents a list of the breakpoints current in use. The pushbutton
 allows a breakpoint to be 'disabled' without removing it. Expressions
 can be applied to the breakpoint.  If the expression evaluates to be
 'true'(results in a defined value that is not 0) the debugger will
 stop the script.  Pressing the 'Goto' button will set the text pane
 to that file and line where the breakpoint is set.  Pressing the
 'Delete' button will delete the breakpoint.

=back

=head1 Menus

=head2 File Menu

=over

=item About...

Presents a dialog box telling you about the version of ptkdb.  It
recovers your OS name, version of perl, version of Tk, and some other
information

=item Open

Presents a list of files that are part of the invoked perl
script. Selecting a file from this list will present this file in the
text window.

=item Save Config...

Requires Data::Dumper. Prompts for a filename to save the
configuration to. Saves the breakpoints, expressions, eval text and
window geometry. If the name given as the default is used and the
script is reinvoked, this configuration will be reloaded
automatically.

    B<NOTE:>  You may find this preferable to using

=item Restore Config...

Requires Data::Dumper.  Prompts for a filename to restore a configuration saved with
the "Save Config..." menu item.

=item Goto Line...

Prompts for a line number.  Pressing the "Okay" button sends the window to the line number entered.
item Find Text...

Prompts for text to search for.  Options include forward search,
backwards search, and regular expression searching.

=item Quit

 Causes the debugger and the target script to exit.

=back

=head2 Control Menu

=over

=item Run

The debugger allows the script to run to the next breakpoint or until the script exits.
item Run To Here

Runs the debugger until it comes to wherever the insertion cursor
in text window is placed.

=item Set Breakpoint

Sets a breakpoint on the line at the insertion cursor.
item Clear Breakpoint

Remove a breakpoint on the at the insertion cursor.

=item Clear All Breakpoints

Removes all current breakpoints

=item Step Over

Causes the debugger to step over the next line.  If the line is a
subroutine call it steps over the call, stopping when the subroutine
returns.

=item Step In

Causes the debugger to step into the next line.  If the line is a
subroutine call it steps into the subroutine, stopping at the first
executable line within the subroutine.

=item Return

Runs the script until it returns from the currently executing
subroutine.

=item Restart

Saves the breakpoints and expressions in a temporary file and restarts
the script from the beginning.  CAUTION: This feature will not work
properly with debugging of CGI Scripts.

=item Stop On Warning

When C<-w> is enabled the debugger will stop when warnings such as, "Use
of uninitialized value at undef_warn.pl line N" are encountered.  The debugger
will stop on the NEXT line of execution since the error can't be detected
until the current line has executed.

This feature can be turned on at startup by adding:

$DB::ptkdb::stop_on_warning = 1 ;

to a .ptkdbrc file

=back

=head2 Data Menu

=over

=item Enter Expression

When an expression is entered in the "Enter Expression:" text box,
selecting this item will enter the expression into the expression
list.  Each time the debugger stops this expression will be evaluated
and its result updated in the list window.

=item Delete Expression

 Deletes the highlighted expression in the expression window.

=item Delete All Expressions

 Delete all expressions in the expression window.

=item Expression Eval Window

Pops up a two pane window. Expressions of virtually unlimitted length
can be entered in the top pane.  Pressing the 'Eval' button will cause
the expression to be evaluated and its placed in the lower pane. If
Data::Dumper is available it will be used to format the resulting
text.  Undo is enabled for the text in the upper pane.

HINT:  You can enter multiple expressions by separating them with commas.

=item Use Data::Dumper for Eval Window

Enables or disables the use of Data::Dumper for formatting the results
of expressions in the Eval window.

=back

=head2 Stack Menu

Maintains a list of the current subroutine stack each time the
debugger stops. Selecting an item from this menu will set the text in
the code window to that particular subourtine entry point.

=head2 Bookmarks Menu

Maintains a list of bookmarks.  The booksmarks are saved in ~/.ptkdb_bookmarks

=over

=item Add Bookmark

Adds a bookmark to the bookmark list.

=back

=head1 Options

Here is a list of the current active XResources options. Several of
these can be overridden with environmental variables. Resources can be
added to .Xresources or .Xdefaults depending on your X configuration.
To enable these resources you must either restart your X server or use
the xrdb -override resFile command.  xfontsel can be used to select
fonts.

    /*
    * Perl Tk Debugger XResources.
    * Note... These resources are subject to change.
    *
    * Use 'xfontsel' to select different fonts.
    *
    * Append these resource to ~/.Xdefaults | ~/.Xresources
    * and use xrdb -override ~/.Xdefaults | ~/.Xresources
    * to activate them.
    */
    /* Set Value to se to place scrollbars on the right side of windows
  CAUTION:  extra whitespace at the end of the line is causing
    failures with Tk800.011.

    sw -> puts scrollbars on left, se puts scrollars on the right

    */
    ptkdb*scrollbars: sw
    /* controls where the code pane is oriented, down the left side, or across the top */
    /* values can be set to left, right, top, bottom */
    ptkdb*codeside: left

    /*
    * Background color for the balloon
    * CAUTION:  For certain versions of Tk trailing
    * characters after the color produces an error
    */
    ptkdb.frame2.frame1.rotext.balloon.background: green
    ptkdb.frame2.frame1.rotext.balloon.font: fixed                       /* Hot Variable Balloon Font */


    ptkdb.frame*font: fixed                           /* Menu Bar */
    ptkdb.frame.menubutton.font: fixed                /* File menu */
    ptkdb.frame2.frame1.rotext.font: fixed            /* Code Pane */
    ptkdb.notebook.datapage.frame1.hlist.font: fixed  /* Expression Notebook Page */

    ptkdb.notebook.subspage*font: fixed               /* Subroutine Notebook Page */
    ptkdb.notebook.brkptspage*entry.font: fixed       /* Delete Breakpoint Buttons */
    ptkdb.notebook.brkptspage*button.font: fixed      /* Breakpoint Expression Entries */
    ptkdb.notebook.brkptspage*button1.font: fixed     /* Breakpoint Expression Entries */
    ptkdb.notebook.brkptspage*checkbutton.font: fixed /* Breakpoint Checkbuttons */
    ptkdb.notebook.brkptspage*label.font: fixed       /* Breakpoint Checkbuttons */

    ptkdb.toplevel.frame.textundo.font: fixed         /* Eval Expression Entry Window */
    ptkdb.toplevel.frame1.text.font: fixed            /* Eval Expression Results Window */
    ptkdb.toplevel.button.font:  fixed                /* "Eval..." Button */
    ptkdb.toplevel.button1.font: fixed                /* "Clear Eval" Button */
    ptkdb.toplevel.button2.font: fixed                /* "Clear Results" Button */
    ptkdb.toplevel.button3.font: fixed                /* "Clear Dismiss" Button */

    /*
    * Background color for where the debugger has stopped
    */
    ptkdb*stopcolor: blue

    /*
    * Background color for set breakpoints
    */
    ptkdb*breaktagcolor*background: yellow
    ptkdb*disabledbreaktagcolor*background: white
    /*
    * Font for where the debugger has stopped
    */
    ptkdb*stopfont: -*-fixed-bold-*-*-*-*-*-*-*-*-*-*-*

    /*
    * Background color for the search tag
    */
    ptkdb*searchtagcolor: green

=head1 Environmental Variables

=over 4

=item PTKDB_BRKPT_COLOR

Sets the background color of a set breakpoint

=item PTKDB_DISABLEDBRKPT_COLOR

Sets the background color of a disabled breakpoint

=item PTKDB_CODE_FONT

Sets the font of the Text in the code pane.

=item PTKDB_CODE_SIDE

Sets which side the code pane is packed onto.  Defaults to 'left'.
Can be set to 'left', 'right', 'top', 'bottom'.

Overrides the Xresource ptkdb*codeside: I<side>.

=item PTKDB_EXPRESSION_FONT

 Sets the font used in the expression notebook page.

=item PTKDB_EVAL_FONT

 Sets the font used in the Expression Eval Window

=item PTKDB_EVAL_DUMP_INDENT

 Sets the value used for Data::Dumper 'indent' setting. See man Data::Dumper

=item PTKDB_SCROLLBARS_ONRIGHT

 A non-zero value Sets the scrollbars of all windows to be on the
 right side of the window. Useful for Windows users using ptkdb in an
 XWindows environment.

=item PTKDB_LINENUMBER_FORMAT

Sets the format of line numbers on the left side of the window.  Default value is %05d.  useful
if you have a script that contains more than 99999 lines.

=item PTKDB_DISPLAY

Sets the X display that the ptkdb window will appear on when invoked.  Useful for debugging CGI
scripts on remote systems.

=item PTKDB_BOOKMARKS_PATH

Sets the path of the bookmarks file.  Default is $ENV{'HOME'}/.ptkdb_bookmarks

=item PTKDB_STOP_TAG_COLOR

Sets the color that highlights the line where the debugger is stopped

=back

=head1 FILES

=head2 .ptkdbrc

If this file is present in ~/ or in the directory where perl is
invoked the file will be read and executed as a perl script before the
debugger makes its initial stop at startup.  There are several 'api'
calls that can be used with such scripts. There is an internal
variable $DB::no_stop_at_start that may be set to non-zero to prevent
the debugger from stopping at the first line of the script.  This is
useful for debugging CGI scripts.

There is a system ptkdbrc file in $PREFIX/lib/perl5/$VERS/Devel/ptkdbrc

=over 4

=item brkpt($fname, @lines)

Sets breakspoints on the list of lines in $fname.  A warning message
is generated if a line is not breakable.

=item condbrkpt($fname, @($line, $expr) )

Sets conditional breakpoints in $fname on pairs of $line and $expr. A
warning message is generated if a line is not breakable.  NOTE: the
validity of the expression will not be determined until execution of
that particular line.

=item brkonsub(@names)

Sets a breakpoint on each subroutine name listed. A warning message is
generated if a subroutine does not exist.  NOTE: for a script with no
other packages the default package is "main::" and the subroutines
would be "main::mySubs".

=item brkonsub_regex(@regExprs)

Uses the list of @regExprs as a list of regular expressions to set breakpoints.  Sets breakpoints
on every subroutine that matches any of the listed regular expressions.

=item textTagConfigure(tag, ?option?, ?value?)

Allows the user to format the text in the code window. The option
value pairs are the same values as the option for the tagConfigure
method documented in Tk::Text. Currently the following tags are in
effect:


    'code'               Format for code in the text pane
    'stoppt'             Format applied to the line where the debugger is currently stopped
    'breakableLine'      Format applied to line numbers where the code is 'breakable'
    'nonbreakableLine'   Format applied to line numbers where the code is no breakable
    'breaksetLine'       Format applied to line numbers were a breakpoint is set
    'breakdisabledLine'  Format applied to line numbers were a disabled breakpoint is set
    'search_tag'         Format applied to text when located by a search.

 Example:

 #
 # Turns off the overstrike on lines that you can't set a breakpoint on
 # and makes the text color yellow.
 #
    textTagConfigure('nonbreakableLine', -overstrike => 0, -foreground => "yellow") ;

=item add_exprs(@exprList)

Add a list of expressions to the 'Exprs' window. NOTE: use the single
quote character \' to prevent the expression from being "evaluated" in
the string context.


  Example:

    #
    # Adds the $_ and @_ expressions to the active list
    #

    add_exprs('$_', '@_') ;

=back

=head1 NOTES

=head2 Debugging Other perlTk Applications

ptkdb can be used to debug other perlTk applications if some cautions
are observed. Basically, do not click the mouse in the application's
window(s) when you've entered the debugger and do not click in the
debugger's window(s) while the application is running.  Doing either
one is not necessarily fatal, but it can confuse things that are going
on and produce unexpected results.

Be aware that most perlTk applications have a central event loop.
User actions, such as mouse clicks, key presses, window exposures, etc
will generate 'events' that the script will process. When a perlTk
application is running, its 'MainLoop' call will accept these events
and then dispatch them to appropriate callbacks associated with the
appropriate widgets.

Ptkdb has its own event loop that runs whenever you've stopped at a
breakpoint and entered the debugger. However, it can accept events
that are generated by other perlTk windows and dispatch their
callbacks.  The problem here is that the application is supposed to be
'stopped', and logically the application should not be able to process
events.

A future version of ptkdb will have an extension that will 'filter'
events so that application events are not processed while the debugger
is active, and debugger events will not be processed while the target
script is active.

=head2 Debugging CGI Scripts

One advantage of ptkdb over the builtin debugger(-d) is that it can be
used to debug CGI perl scripts as they run on a web server. Be sure
that that your web server's perl instalation includes Tk.

Change your

  #! /usr/local/bin/perl

to

  #! /usr/local/bin/perl -d:ptkdb

TIP: You can debug scripts remotely if you're using a unix based
Xserver and where you are authoring the script has an Xserver.  The
Xserver can be another unix workstation, a Macintosh or Win32 platform
with an appropriate XWindows package.  In your script insert the
following BEGIN subroutine:

    sub BEGIN {
      $ENV{'DISPLAY'} = "myHostname:0.0" ;
    }

Be sure that your web server has permission to open windows on your
Xserver (see the xhost manpage).

Access your web page with your browswer and 'submit' the script as
normal.  The ptkdb window should appear on myHostname's monitor. At
this point you can start debugging your script.  Be aware that your
browser may timeout waiting for the script to run.

To expedite debugging you may want to setup your breakpoints in
advance with a .ptkdbrc file and use the $DB::no_stop_at_start
variable.  NOTE: for debugging web scripts you may have to have the
.ptkdbrc file installed in the server account's home directory (~www)
or whatever username your webserver is running under.  Also try
installing a .ptkdbrc file in the same directory as the target script.

=head1 KNOWN PROBLEMS

=over

=item I<Breakpoint Controls>

If the size of the right hand pane is too small the breakpoint controls
are not visible.  The breakpoints are still there, the window may have
to be enlarged in order for them to be visible.

=item Balloons and Tk400

The Balloons in Tk400 will not work with ptkdb.  All other functions
are supported, but the Balloons require Tk800 or higher.

=back

=head1 AUTHOR

Andrew E. Page, aepage@users.sourceforge.net

=head1 ACKNOWLEDGEMENTS

Matthew Persico    For suggestions, and beta testing.

=head1 BUG REPORTING

Please report bugs through the following URL:

http://sourceforge.net/tracker/?atid=437609&group_id=43854&func=browse

=cut

# ptkdb.pm,v
# Revision 1.15  2004/03/31 02:08:40  aepage
# fixes for various lacks of backwards compatiblity in Tk804
# Added a 'bug report' item to the File Menu.
#
# Revision 1.14  2003/11/20 01:59:40  aepage
# version fix
#
# Revision 1.12  2003/11/20 01:46:45  aepage
# Hex Dumper and correction of some parameters for Tk804.025_beta6
#
# Revision 1.11  2003/06/26 13:42:49  aepage

#
# Revision 1.10  2003/05/12 14:38:34  aepage
# win32 pushback
#
# Revision 1.9  2003/05/12 13:46:46  aepage
# optmization of win32 line fixing
#
# Revision 1.8  2003/05/11 23:42:20  aepage
# fix to remove stray win32 chars
#
# Revision 1.7  2003/05/11 23:15:26  aepage
# email address changes, fixes for perl 5.8.0
#
# Revision 1.6  2002/11/28 19:17:43  aepage
# Changed many options to widgets and pack from bareword or 'bareword'
# to -bareword to support Tk804.024(Devel).
#
# Revision 1.5  2002/11/25 23:47:03  aepage
# A perl debugger package is required to define a subroutine name 'sub'.
# This routine is a 'proxy' for handling subroutine calls and allows the
# debugger pacakage to track subroutine depth so that it can implement
# 'step over', 'step in' and 'return' functionality.  It must also
# handle the same context as the proxied routine; it must return a
# scalar where a scalar was being expected, an array where an array is
# being expected and a void where a void was being expected.  Ptkdb was
# not handling the case for void.  99.9% of the time this will have no
# ill effects although it is being handled incorrectly. Ref Programming
# Perl 3rd Edition pg 827
#
# Revision 1.4  2002/10/24 17:07:10  aepage
# fix for warning for undefined value assigend to typeglob during restart
#
# Revision 1.3  2002/10/20 23:49:51  aepage
#
# changed email address to aepage@ptkdb.sourceforge.net
#
# localized $^W in dbeval
#
# fix for instances where there is no code in a package.
#
# Initialized $self->{'subs_list_cnt'} in the new constructor to 0 to
# prevent warnings with -w.
#

1;

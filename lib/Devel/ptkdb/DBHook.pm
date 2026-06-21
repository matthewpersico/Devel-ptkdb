## no critic (Modules::RequireFilenameMatchesPackage)
package DB;

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Core and CPAN modules
use Carp;

# ===========================================================================
# Project modules
# None

# ===========================================================================
# Shareable package data
# None

# ===========================================================================
# Package data
my %PD = (
    brkpt_search_line_count => 20,
);

# ===========================================================================
# Package functions

# ===========================================================================
# Devel::ptkdb access
sub debug_say {
    goto &Devel::ptkdb::debug_say;
}

# ===========================================================================
# dbline handlers
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

    # Yes, we are checking for the debugger injecting itself on the first line
    # of the code, which is typically the zeroth [0] element.  But not in the
    # debugger. Apparently the zeroth element of *dbline goes unused <facepalm>.
    my $diio = defined $lines->[1] && $lines->[1] =~ /use\s+.*Devel::_?ptkdb/ ? 1 : 0;
    if ($diio) {
        debug_say(
            msg    => "Offset adjusted!",
            action => 'trace',
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

# ===========================================================================
# breakpoint handlers

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
    my @brkpt_fixed_msg;
    BREAKPOINTS:
    foreach my $brkpt (@{ $args{brkpts} }) {
        $found = 0;

        # We compare code lines sans whitespace to help match in the face of
        # perl tidying.
        my $code_text = '';
        if (defined $args{lines}->[$brkpt->{line}]) {
            $code_text = $args{lines}->[$brkpt->{line}];
            $code_text =~ s/\s+//g;
        }
        my $brkpt_text = $brkpt->{text} // q{};
        $brkpt_text =~ s/\s+//g;
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

            NEARBY_SEARCH:
            for ((reverse $startLine .. $pivot), $pivot + 1 .. $endLine) {
                $code_text = $args{lines}->[$_];
                $code_text =~ s/\s+//g;
                my ($pkg, $file, $line, $sub) = caller(0);
                next unless $brkpt_text eq $code_text;
                push @brkpt_fixed_msg,
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
                    push @brkpt_fixed_msg,
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
            push @brkpt_fixed_msg,
                (
                "Breakpoint $args{fname} (line $brkpt->{line})",
                " for statement [$text]",
                " is lost due to code changes.",
                q()
                );
        }
    }
    scalar(@brkpt_fixed_msg) && Devel::ptkdb::obj()->do_alert(
        title => 'Breakpoint Load',
        msg   => \@brkpt_fixed_msg
    );

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
        my $lines       = _dbline_array($fname);
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
                Devel::ptkdb::obj()->do_alert(
                    title => 'Breakpoint Restore',
                    msg   => "Breakpoint $fname:$brkpt->{line} in config file is not breakable."
                );
                next;
            }
            $breakpoints->{ $brkpt->{line} } = { %{$brkpt} };
        }
    }

    return;
}

# ===========================================================================
# state handlers
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
    my $ptkdb_obj = Devel::ptkdb::obj();

    #
    # Update expressions
    #
    $ptkdb_obj->deleteAllExprs();
    my (@result);

    for my $expr (@{ $ptkdb_obj->{'expr_list'} }) {
        next if length $expr == 0;

        @result = &DB::dbeval($package, $expr->{'expr'});

        if (@result == 1) {
            $ptkdb_obj->insertExpr(
                [$result[0]],
                $ptkdb_obj->{'data_list'},
                $result[0], $expr->{'expr'}, $expr->{'depth'}
            );
        } else {
            $ptkdb_obj->insertExpr(
                [\@result],
                $ptkdb_obj->{'data_list'},
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
    my ($fname) = @_;
    return if $DB::ptkdb::isInitialized;
    $DB::ptkdb::isInitialized = 1;

    my $ptkdb_obj = Devel::ptkdb::obj();
    return unless defined $ptkdb_obj;

    $ptkdb_obj->do_user_init_files();

    $DB::dbint_handler_save = $SIG{'INT'}         unless $DB::sigint_disable;    # saves the old handler
    $SIG{'INT'}             = "DB::dbint_handler" unless $DB::sigint_disable;

    # Check for a 'restart' file

    if ($ENV{'PTKDB_RESTART_STATE_FILE'}
        && -e $ENV{'PTKDB_RESTART_STATE_FILE'}) {
        #
        # Restore expressions and breakpoints in state file
        #
        print "restoring state from $ENV{'PTKDB_RESTART_STATE_FILE'}\n";
        $ptkdb_obj->restore_state_file($ENV{'PTKDB_RESTART_STATE_FILE'});
        unlink $ENV{'PTKDB_RESTART_STATE_FILE'};    # delete state file
        $ENV{'PTKDB_RESTART_STATE_FILE'} = "";      # clear entry
    } else {
        $ptkdb_obj->restore_state_file();           # look for a default based on $0
    }

}

sub restoreState {
    my ($fname) = @_;
    my $ptkdb_obj = Devel::ptkdb::obj();
    return $ptkdb_obj->restore_state_file($fname);
}

sub save_state_file {
    my ($fname) = @_;
    my $ptkdb_obj = Devel::ptkdb::obj();
    return $ptkdb_obj->save_state_file($fname);
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
    my $ptkdb_obj = Devel::ptkdb::obj();

    $ptkdb_obj->do_alert(msg => $@) if $@;

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

        my $ptkdb_obj = Devel::ptkdb::obj();
        if (!$ptkdb_obj) {    # not setup yet
            $@ = $DB::save_err;
            return;
        }

        $ptkdb_obj->setup_main_window() unless $ptkdb_obj->{'main_window'};

        $ptkdb_obj->EnterActions();

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

        $ptkdb_obj->focus_debugger_command_widget();
        $ptkdb_obj->{main_window}->focus();

        $ptkdb_obj->set_file($filename, $line);
        #
        # Refresh the exprs to see if anything has changed
        #
        updateExprs($package);

        #
        # Update subs Page if necessary
        #
        $cnt = scalar keys %DB::sub;
        if ($cnt != $ptkdb_obj->{'subs_list_cnt'} && $ptkdb_obj->{'subs_page_activated'}) {
            $ptkdb_obj->fill_subs_page();
            $ptkdb_obj->{'subs_list_cnt'} = $cnt;
        }
        #
        # Update the subroutine stack menu
        #
        $ptkdb_obj->refresh_stack_menu();

        $ptkdb_obj->{run_flag} = 1;

        my ($evt, @result, $r);

        for (;;) {
            #
            # we wait here for something to do
            #
            $evt = $ptkdb_obj->main_loop();

            last if ($evt eq 'step');

            $DB::single = 0 if ($evt eq 'run');

            if ($evt eq 'balloon_eval') {
                $ptkdb_obj->code_motion_eval(&DB::dbeval($package, $ptkdb_obj->{'balloon_expr'}));
                next;
            }

            if ($evt eq 'qexpr') {
                my $str;
                @result = &DB::dbeval($package, $ptkdb_obj->{'qexpr'});
                $ptkdb_obj->{'quick_entry'}->delete(0, 'end');    # clear old text
                if (exists $ptkdb_obj->{'quick_dumper'}) {
                    $ptkdb_obj->{'quick_dumper'}->Reset();
                    $ptkdb_obj->{'quick_dumper'}->Values([$#result == 0 ? @result : \@result]);
                    if ($ptkdb_obj->{'quick_dumper'}->can('Dumpxs')) {
                        $str = $ptkdb_obj->{'quick_dumper'}->Dumpxs();
                    } else {
                        $str = $ptkdb_obj->{'quick_dumper'}->Dump();
                    }
                } else {
                    $str = "@result";
                }
                $ptkdb_obj->{'quick_entry'}->insert(0, $str);             #enter the text
                $ptkdb_obj->{'quick_entry'}->selectionRange(0, 'end');    # select it
                $evt = 'update';                                          # force an update on the expressions
            }

            if ($evt eq 'expr') {
                #
                # Append the new expression to the list
                # but first check to make sure that we don't
                # already have it.
                #

                if (grep $_->{'expr'} eq $ptkdb_obj->{'expr'}, @{ $ptkdb_obj->{'expr_list'} }) {
                    $ptkdb_obj->do_alert(msg => "$ptkdb_obj->{'expr'} is already listed");
                    next;
                }

                @result = &DB::dbeval($package, $ptkdb_obj->{expr});

                if (@result == 1) {
                    $r = $ptkdb_obj->insertExpr(
                        [$result[0]],
                        $ptkdb_obj->{'data_list'},
                        $result[0], $ptkdb_obj->{'expr'}, $ptkdb_obj->{'expr_depth'}
                    );
                } else {
                    $r = $ptkdb_obj->insertExpr(
                        [\@result],
                        $ptkdb_obj->{'data_list'},
                        \@result, $ptkdb_obj->{'expr'}, $ptkdb_obj->{'expr_depth'}
                    );
                }

                #
                # $r will be 1 if the expression was added succesfully, 0 if not,
                # and it if wasn't added sucessfully it won't be reevalled the
                # next time through.
                #
                push @{ $ptkdb_obj->{'expr_list'} },
                    { 'expr' => $ptkdb_obj->{'expr'}, 'depth' => $$ptkdb_obj->{'expr_depth'} }
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
                my $txt    = $ptkdb_obj->{'eval_text'}->get('0.0', 'end');
                my @result = &DB::dbeval($package, $txt);

                $ptkdb_obj->updateEvalWindow(@result);

                next;
            }
            last;
        }
        $^P = $saveP;
        $SIG{'INT'} = "DB::dbint_handler" unless $DB::sigint_disable;    # set our signal handler

        $ptkdb_obj->LeaveActions();

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

1;

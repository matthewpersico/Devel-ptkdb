package Devel::ptkdb;

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Core and CPAN modules
use Carp qw(cluck carp confess longmess);
use Config;
use Cwd qw(realpath cwd);
use Data::Dumper;
use Devel::PL_origargv;
use File::Basename qw(dirname basename);
use FileHandle;
use File::Spec;
use POSIX qw(strftime);
use Ref::Util qw(is_plain_arrayref is_ref);
use Tk;
use Tk::Adjuster;
use Tk::Balloon;
use Tk::Dialog;
use Tk::HList;
use Tk::NoteBook;
use Tk::ROText;
use Tk::Table;
use Tk::TextUndo;
use Tk::Tree;

# ===========================================================================
# Project modules
use Devel::ptkdb::Cmd;
use Devel::ptkdb::InitAPI;
use Devel::ptkdb::Playlist;
use Devel::ptkdb::State;

# ===========================================================================
# Shareable package data

# We store the debugger object from new() here. Other packages will need to
# access it, but if we start using this module in other modules, we end up ion
# curcular dependncy hell. So, after we create and store it here, other modules
# can access it via Deve::ptkdb::ptkdb_obj() accessor function.
our $VERSION = "2.0.0";

# ===========================================================================
# Package data
my $_ptkdb_obj;                        # Storage for the ptkdb object for
                                       # access by other modules via
                                       # Devel::ptkdb::obj().
our $_ptkdb_obj_is_being_built = 0;    # Needs to be 'our' so we can 'local'
                                       # it.
my $isWin32 = $^O eq 'MSWin32';

my $dumpFunc = (
    Data::Dumper->can('Dumpxs')
    ? 'Dumpxs'
    : 'Dump'
);

my %KEY_BINDINGS = (
    close_window_and_run => { event => '<Control-w>', accelerator => 'Ctrl+W' },
    enter_expression     => { event => '<Control-e>', accelerator => 'Ctrl+E' },
    eval_window          => { event => '<Control-E>', accelerator => 'Ctrl+Shift+E' },
    find_text            => { event => '<Control-f>', accelerator => 'Ctrl+F' },
    focus_code           => { event => '<Control-1>', accelerator => 'Ctrl+1' },
    focus_expr           => { event => '<Control-3>', accelerator => 'Ctrl+3' },
    focus_quick_expr     => { event => '<Control-2>', accelerator => 'Ctrl+2' },
    goto_line            => { event => '<Control-g>', accelerator => 'Ctrl+G' },
    interrupt            => { event => '<Control-c>', accelerator => 'Ctrl+C' },
    open_file            => { event => '<Control-o>', accelerator => 'Ctrl+O' },
    quit                 => { event => '<Control-q>', accelerator => 'Ctrl+Q' },
    restart              => { event => '<Control-r>', accelerator => 'Ctrl+R' },
    run                  => { event => '<F5>',        accelerator => 'F5' },
    run_to_here          => { event => '<Shift-F5>',  accelerator => 'Shift+F5' },
    step_in              => { event => '<F11>',       accelerator => 'F11' },
    step_out             => { event => '<Shift-F11>', accelerator => 'Shift+F11' },
    step_over            => { event => '<F10>',       accelerator => 'F10' },
    toggle_breakpoint    => { event => '<F9>',        accelerator => 'F9' },
);

# ===========================================================================
# Object static methods

# We define here(), console_say(), and debug_say() at this place in the code so
# they can be used in BEGIN. If you want to use them in other Devel::ptkdb
# modules, either type out the Devel::ptkdb:: qualifier on each call, or subs
# in those modules like this:
#
# sub console_say {
#    goto &Devel::ptkdb::console_say;
# }
#
# This will invoke the call, with the same arguments, replacing the stack frame
# (avoiding chatter in any stack traces), without the need for importing, which
# could cause a circular module inclusion issue.

sub here {
    my $level = ($_[0] ||= 0);
    # caller() doesn't cut it for what we want, which is effectively:
    #
    # (caller(0))[3], __FILE__, __LINE__
    #
    # This is because caller() gives the location from where a sub called, not
    # where we are in such a sub. And there is no way to use __FILE__ and
    # __LINE__ in a function because the are evaluated at compile time; they
    # would be the __FILE__ and __LINE__ of where they exist, not of any
    # calling sub. Therefore, we use two calls to caller() to get what we want.
    #
    # When caller is 0, we get where here() was called from, which is where the
    # caller "is", and this function name of here(), which we ignore.
    #
    # When caller is 1, we get the caller of here().
    #
    # That combination prints where in the code we put the here() call, by
    # file, line and sub.
    #
    # We default level to 0, which is useful for most purposes, but allow it to be
    # specified so we can use it internally in our *say* functions.
    my ($pkg, $file, $line, $d4)  = caller($level);
    my ($d1,  $d2,   $d3,   $sub) = caller($level + 1);

    return    # instead of sprintf '%s [%s:%d]',
        (($sub // '<main>') . q( [) . $file . q(:) . $line . q(]));
}

sub _console_prompt {
    my %args = (
        msg => '',
        _id => '_console_prompt',
        @_
    );
    my @msg;
    if (is_plain_arrayref($args{msg})) {
        push @msg, @{ $args{msg} };
    } else {
        push @msg, $args{msg};
    }
    my $msg_string = join("\n", map { split(/\n/, $_) } @msg);
    chomp $msg_string;
    return ($args{_id} . ($args{_where} ? " (in $args{_where})" : q()) . "> $msg_string" . qq(\n));
}

sub console_say {
    my %args;
    if (scalar(@_) == 1) {
        # simple text print
        $args{msg}    = $_[0];
        $args{_id}    = 'ptkdb';
        $args{_where} = '';
    } else {
        %args = (
            _id    => 'console_say',
            _where => here(1),
            @_
        );
    }
    print(_console_prompt(%args));
}

sub debug_say {
    my %args = (
        _where => here(1),
        msg    => '',
        action => 'continue',
        dump   => [],
        _id    => 'debug_say',
        @_
    );
    my $dump = (
        is_ref($args{dump})
        ? $args{dump}
        : [$args{dump}]
    );
    my $output = join(
        qq(\n),
        '',
        _console_prompt(%args),
        Data::Dumper->$dumpFunc([$dump], [qw(*dumped_data)])
    );

    for ($args{action}) {
        # Use 'skip' when you temporarily do not want any output.
        /skip/ && do {
            next;
        };
        # Use 'continue' when you temporarily do not want a trace but do want
        # the message
        /continue/ && do {
            print $output;
            next;
        };
        /dietrace/ && do {
            confess $output;
            next;
        };
        /warntrace/ && do {
            cluck $output;
            next;
        };
        /die/ && do {
            croak $output;
            next;
        };
        /warn/ && do {
            carp $output;
            next;
        };
        /trace/ && do {
            print $output . longmess();
            next;
        };
        otherwise:
        confess
            "action '$args{action}' not one of skip, continue, trace, warn, warntrace, die, dietrace";
    }
}

sub obj {
    return $_ptkdb_obj if defined $_ptkdb_obj;

    return undef if $_ptkdb_obj_is_being_built;    ## no critic (Subroutines::ProhibitExplicitReturnUndef)

    local $_ptkdb_obj_is_being_built = 1;
    $_ptkdb_obj = __PACKAGE__->new;

    return $_ptkdb_obj;
}

sub key_event {
    my ($self, $name) = @_;
    return $KEY_BINDINGS{$name}->{event};
}

sub key_accelerator {
    my ($self, $name) = @_;
    return $KEY_BINDINGS{$name}->{accelerator};
}

sub bind_key {
    my ($self, $name, $callback) = @_;

    $self->{main_window}->bind($self->key_event($name), $callback);
    return;
}

sub font_settings {
    my ($self, $type) = @_;

    my %font_env = (
        code => 'PTKDB_CODE_FONT',
        gui  => 'PTKDB_GUI_FONT',
    );
    my %default_font = (
        code => 'Courier 10',
        gui  => undef,
    );

    confess "Unknown font type '$type'" unless exists $font_env{$type};

    my $font = $ENV{ $font_env{$type} } || $default_font{$type};
    return $font ? { -font => $font } : {};
}

sub apply_font_settings {
    my ($self, $widget, $type) = @_;

    my $settings = $self->font_settings($type);
    return unless $widget && %{$settings};

    eval { $widget->configure(%{$settings}); };
    if ($widget->can('children')) {
        for my $child ($widget->children) {
            $self->apply_font_settings($child, $type);
        }
    }

    return;
}

sub code_item_style_args {
    my ($self, $widget, $item_type) = @_;
    $item_type ||= 'text';

    my $settings = $self->font_settings('code');
    return unless $widget && %{$settings};

    my $key = "$widget:$item_type";
    if (!exists $self->{code_item_styles}->{$key}) {
        $self->{code_item_styles}->{$key} = eval { $widget->ItemStyle($item_type, %{$settings}) };
        if (!$self->{code_item_styles}->{$key} && $widget->can('children')) {
            CHILD:
            for my $child ($widget->children) {
                my @child_style = $self->code_item_style_args($child, $item_type);
                if (@child_style) {
                    $self->{code_item_styles}->{$key} = $child_style[1];
                    last CHILD;
                }
            }
        }
    }

    my $style = $self->{code_item_styles}->{$key};
    return $style ? (-style => $style) : ();
}

# ===========================================================================
# Object instance methods

sub new {
    my ($type) = @_;
    my ($self) = {};

    bless $self, $type;
    # The whole command - perl exec, perl args, program, program args
    $self->{restart_cmd} = [Devel::PL_origargv->get()];

    # ENV - We will want to restore the original environment when we
    # restart, especially since the environment contains PATH; if
    # perl was invoked as 'perl', we will need to have the same PATH
    # in place to get the same perl we started with.
    $self->{restart_ENV} = \%ENV;

    # Location - we need to go back to where we started, or else you
    # may not find $0.
    $self->{restart_dir} = cwd();

    # Handles .ptkdb file saves and loads.
    $self->{state_manager} = Devel::ptkdb::State->new(ptkdb_obj => $self);
    $self->{script_name}   = $0;
    # copy args, don't point at them
    $self->{script_args} = [@ARGV];

    # List o' Widgets to disable when leaving the debugger
    $self->{DisableOnLeave} = [];

    $self->{current_file} = q();
    # initial value indicating we haven't set our line/tag
    $self->{current_line} = -1;
    # when we enter how far from the top of the text are we positioned down
    $self->{window_pos_offset} = 10;
    $self->{search_start}      = "0.0";
    $self->{fwdOrBack}         = 1;
    $self->{BookMarksPath}
        = $ENV{'PTKDB_BOOKMARKS_PATH'} || "$ENV{'HOME'}/.ptkdb_bookmarks" || '.ptkdb_bookmarks';

    # list of expressions to eval in our window fields: {'expr'} The expr
    # itself {'depth'} expansion depth
    $self->{'expr_list'} = [];

    $self->{'brkpt_cnt'} = 0;
    # open slots for adding breakpoints to the table
    $self->{'brkpt_slots'} = [];

    $self->{'user_window_init_list'}     = [];
    $self->{'user_window_DB_entry_list'} = [];

    $self->{'subs_list_cnt'} = 0;

    $self->{'pathSep'}            = '\x00';
    $self->{'pathSepReplacement'} = "\0x01";
    $self->{'step_in_keys'}       = [$self->key_event('step_in')];      # step into a subroutine
    $self->{'step_over_keys'}     = [$self->key_event('step_over')];    # step over a subroutine
    $self->{'return_keys'}        = [$self->key_event('step_out')];     # return from a subroutine

    # These will be bound only to the code pane, so that other widgets can have
    # Their own popup menus
    $self->{'step_in_mouse'}       = ['<Button-3>'];                             # step into a subroutine
    $self->{'step_over_mouse'}     = ['<Shift-Button-3>'];                       # step over a subroutine
    $self->{'return_mouse'}        = ['<Control-Button-3>'];                     # return from a subroutine
    $self->{'toggle_breakpt_keys'} = [$self->key_event('toggle_breakpoint')];    # set or unset a breakpoint

    $self->{'eval_dump_indent'} = $ENV{'PTKDB_EVAL_DUMP_INDENT'} || 1;

    #
    # Windows users are more used to having scroll bars on the right.
    # If they've set PTKDB_SCROLLBARS_ONRIGHT to a non-zero value
    # this will configure our scrolled windows with scrollbars on the right
    #
    # this can also be done by setting:
    #
    # ptkdb*scrollbars: se
    #
    # in the .Xdefaults/.Xresources file on X based systems
    #
    if (exists $ENV{'PTKDB_SCROLLBARS_ONRIGHT'} && $ENV{'PTKDB_SCROLLBARS_ONRIGHT'}) {
        $self->{'scrollbar_cfg'} = { '-scrollbars' => 'se' };
    } else {
        $self->{'scrollbar_cfg'} = {};
    }

    # Controls how far an expression result will be 'decomposed'.  Setting it
    # to 0 will take it down only one level, setting it to -1 will make it
    # decompose it all the way down. However, if you have a situation where an
    # element is a ref back to the array or a root of the array you could hang
    # the debugger by making it recursively evaluate an expression
    $self->{expr_depth}       = -1;
    $self->{'add_expr_depth'} = 1;    # how much further to expand an expression when clicked

    $self->{'linenumber_format'} = $ENV{'PTKDB_LINENUMBER_FORMAT'} || "%05d ";
    # If you have more than 99,999 lines in any one file, you're doing
    # something wrong!
    $self->{'linenumber_length'} = 5;
    $self->{'linenumber_offset'} = length sprintf($self->{'linenumber_format'}, 0);
    $self->{'linenumber_offset'} -= 1;

    $self->setup_main_window();

    return $self;

}

sub do_alert {
    my $self = shift;
    my %args = (
        title => 'ptkdb alert (' . here(1) . ')',
        msg   => 'Unspecified alert.  (' . here(1) . ')',
        @_
    );

    my $message = (
        is_plain_arrayref($args{msg})
        ? join(
            qq(\n),
            map { split(/\n/, $_) } @{ $args{msg} }
            )
        : $args{msg}
    );

    my $previous_focus = $self->{main_window}->focusCurrent();
    my $top            = $self->{main_window}->Toplevel(-title => $args{title});

    $top->transient($self->{main_window});

    $top->Label(
        -text       => $message,
        -justify    => 'left',
        -wraplength => 600,
        %{ $self->font_settings('gui') },
    )->pack(
        -side   => 'top',
        -fill   => 'both',
        -expand => 1,
        -padx   => 10,
        -pady   => 10,
    );

    $top->Button(
        -text    => 'OK',
        -command => sub { $top->destroy(); },
        %{ $self->font_settings('gui') },
    )->pack(
        -side => 'bottom',
        -pady => 10,
    );

    $top->bind(
        '<Destroy>' => sub {
            if ($previous_focus && Tk::Exists($previous_focus)) {
                $previous_focus->afterIdle(
                    sub {
                        $previous_focus->focusForce();
                        $previous_focus->icursor('end')
                            if $previous_focus->can('icursor');
                    }
                );
            } else {
                $self->focus_debugger_command_entry();
            }
        }
    );

    return;
}

sub error_dialog {
    my $self = shift;
    my %args = (
        title => 'ptkdb error (' . here_parent() . ')',
        msg   => 'Unspecified error (' . here_parent() . ')',
        @_
    );

    my $message = (
        is_plain_arrayref($args{msg})
        ? join(
            qq(\n),
            map { split(/\n/, $_) } @{ $args{msg} }
            )
        : $args{msg}
    );
    my $previous_focus = $self->{main_window}->focusCurrent();

    $self->{main_window}->messageBox(
        %args,
        -type => 'OK',
        -icon => 'error',
    );

    if ($previous_focus && Tk::Exists($previous_focus)) {
        $previous_focus->afterIdle(
            sub {
                $previous_focus->focusForce();
                $previous_focus->icursor('end')
                    if $previous_focus->can('icursor');
            }
        );
    } else {
        $previous_focus->afterIdle(
            sub {
                $self->focus_debugger_command_entry();
            }
        );
    }

    return;
}

sub make_file_save_name {
    my ($self, $filename) = @_;

    $filename =~ s/\.(?:pl|pm|t)\z//;
    return "$filename.ptkdb";
}

sub restore_state_file {
    my ($self, @args) = @_;
    return $self->{state_manager}->restore_state_file(@args);
}

sub save_state_file {
    my ($self, @args) = @_;
    return $self->{state_manager}->save_state_file(@args);
}

sub icon_file {
    my ($self, @path) = @_;

    my $base = __FILE__;
    $base =~ s/\.pm\z//;

    return File::Spec->catfile($base, qw(icons), @path);
}

sub set_window_icon {
    my ($self) = @_;

    my $mw = $self->{main_window};

    my @candidates;
    push @candidates, qw(ptkdb.ico)
        if $^O eq 'MSWin32';

    for my $ext (qw (png gif xpm)) {
        push @candidates, 'ptkdb.' . $ext;
        # This is the preferred order for window managers, according to
        # research.
        for my $size (qw( 32 48 64 24 20 16 128 256)) {
            push @candidates, join(
                '',
                'ptkdb-',
                $size,
                q(.),
                $ext
            );
        }
    }

    for my $icon (@candidates) {
        my $file = $self->icon_file($icon);
        next unless -r $file;

        my $img = eval { $mw->Photo(-file => $file); };
        next unless $img;

        $mw->iconimage($img);
        $mw->Icon(-image => $img) if $mw->can('Icon');

        $self->{window_icon_image} = $img;    # keep alive

        return 1;
    }

    return;
}

# =========================================================================
# Below here is code that existed prior to the re-architecting of
# 2026/June. Any function that can be used will be hoisted up above.

### Object static
sub BEGIN {
    {
        no warnings 'once';
        $DB::on = 0;
    }
    $DB::subroutine_depth = 0;    # our subroutine depth counter
    $DB::step_over_depth  = -1;

    # DB Options (things not directly involving the window)

    # Flag to disable us from intercepting $SIG{'INT'}
    {
        no warnings 'once';
        $DB::sigint_disable = defined $ENV{'PTKDB_SIGINT_DISABLE'} && $ENV{'PTKDB_SIGINT_DISABLE'};
    }

    # Possibly for debugging perl CGI Web scripts on remote machines.
    $ENV{'DISPLAY'} = $ENV{'PTKDB_DISPLAY'} if exists $ENV{'PTKDB_DISPLAY'};
}

sub DoBugReport {
    my $self       = shift;
    my ($str)      = 'sourceforge.net/tracker/?atid=437609&group_id=43854&func=browse';
    my (@browsers) = qw/netscape mozilla/;
    my ($fh, $pid, $sh);

    if ($isWin32) {
        $sh       = '';
        @browsers = '"' . $ENV{'PROGRAMFILES'} . '\\Internet Explorer\\IEXPLORE.EXE' . '"';

    } else {
        $sh  = 'sh';
        $str = "\'http://" . $str . "\'";
    }

    $fh = new FileHandle();

    for (@browsers) {
        $pid = open($fh, "$sh $_ $str 2&> /dev/null |");    ## no critic (InputOutput::ProhibitTwoArgOpen)
        sleep(2);
        waitpid $pid, 0;
        return if ($? == 0);
    }

    print "#\n";
    print "# Please submit a bug report through the following URL:\n";
    print '#    http://sourceforge.net/tracker/?atid=437609&group_id=43854&func=browse', "\n";
    print "#\n";
}

#
# Run files provided by the user
#
sub do_user_init_files {
    my ($self) = @_;

    my @init_files = (
        {   type     => 'system',
            filename => "$Config{'installprivlib'}/Devel/ptkdbrc"
        },
        {   type     => 'user',
            filename => "$ENV{'HOME'}/.ptkdbrc"
        },
        {   type     => 'script',
            filename => realpath(File::Spec->catfile(dirname($self->{'script_name'}), '.ptkdbrc'))
        },
        {   type     => 'local',
            filename => './.ptkdbrc'
        }
    );

    for my $init_file (@init_files) {
        if (!-e $init_file->{filename}) {
            console_say("No $init_file->{type} init file $init_file->{filename} found.");
        } else {
            eval { do "$init_file->{filename}"; };
            if ($@) {
                console_say(
                    ucfirst($init_file->{type}) . " $init_file->{filename} failed to load: $@");
            } else {
                console_say(ucfirst($init_file->{type}) . " $init_file->{filename} loaded.");
            }
        }
    }

    $self->set_stop_on_warning();
}

sub setup_main_window {
    my ($self) = @_;

    # Main Window

    $self->{main_window} = MainWindow->new();
    $self->{main_window}->geometry($ENV{'PTKDB_GEOMETRY'} || "800x600");
    $self->set_window_icon();

    $self->setup_options();    # must be done after MainWindow and before other frames are setup

    $self->bind_key('interrupt', \&DB::dbint_handler);

    #
    # Bind our 'quit' routine to a close command from the window manager (Alt-F4)
    #
    $self->{main_window}->protocol('WM_DELETE_WINDOW', sub { $self->DoQuit(); });

    # Shared between the GUI and the command line
    $self->setup_shared_callbacks();

    # Widgets
    $self->setup_menu_bar();
    $self->setup_button_bar();

    $self->focus_debugger_command_widget();
    $self->setup_frames();    # Setup our Code, Data, and breakpoints

    $self->focus_debugger_command_widget();
}

# Shared between the GUI and the command line
sub setup_shared_callbacks {
    my ($self) = @_;
    $self->{shared_callbacks} = {
        runSub => sub { $DB::step_over_depth = -1; $self->{'event'} = 'run' },

        runToSub => sub {
            $self->{'event'} = 'run' if $self->SetBreakPoint(1);
        },

        stepOverSub => sub {
            &DB::SetStepOverBreakPoint(0);
            $DB::single = 1;
            $self->{'event'} = 'step';
        },

        stepInSub => sub {
            $DB::step_over_depth = -1;
            $DB::single          = 1;
            $self->{'event'}     = 'step';
        },

        returnSub => sub {
            &DB::SetStepOverBreakPoint(-1);
            $self->{'event'} = 'run';
        },

        quitSub => sub {
            $self->DoQuit();
        },
    };
}

sub focus_debugger_command_widget {
    my ($self) = @_;

    my $entry_widget = $self->{debugger_command_widget}
        or return;

    $entry_widget->afterIdle(
        sub {
            $entry_widget->focusForce();
            $entry_widget->icursor('end');
        }
    );

    return;
}
#
# Check for changes to the bookmarks and quit
#
sub DoQuit {
    my ($self) = @_;

    $self->save_bookmarks($self->{BookMarksPath})
        if $self->{'bookmarks_changed'};
    $self->{main_window}->destroy if $self->{main_window};
    $self->{main_window} = undef  if defined $self->{main_window};

    exit;
}

#
# This supports the File -> Open menu item
# We create a new window and list all of the files
# that are contained in the program.  We also
# pick up all of the perlTk files that are supporting
# the debugger.
#
sub DoOpen {
    my $self = shift;
    my ($topLevel, $listBox, $frame, $selectedFile, @fList);

    #
    # subroutine we call when we've selected a file
    #

    my $chooseSub = sub {
        $selectedFile = $listBox->get('active');
        print "attempting to open $selectedFile\n";
        $self->set_file($selectedFile, 0);
        destroy $topLevel;
    };

    #
    # Take the list the files and resort it.
    # we put all of the local files first, and
    # then list all of the system libraries.
    #
    @fList = sort {
        # sort comparison function block
        my $fa = substr($a, 0, 1);
        my $fb = substr($b, 0, 1);

        return $a cmp $b if ($fa eq '/') && ($fb eq '/');

        return -1 if ($fb eq '/') && ($fa ne '/');
        return 1  if ($fa eq '/') && ($fb ne '/');

        return $a cmp $b;

    } grep s/^_<//, keys %main::;

    #
    # Create a list box with all of our files
    # to select from
    #
    $topLevel = $self->{main_window}->Toplevel(-title => "File Select", -overanchor => 'cursor');

    $listBox = $topLevel->Scrolled(
        'Listbox', %{ $self->{'scrollbar_cfg'} },
        %{ $self->font_settings('code') },
        -width => 30
    )->pack(-side => 'top', -fill => 'both', -expand => 1);
    $self->apply_font_settings($listBox, 'code');

    # Bind a double click on the mouse button to the same action
    # as pressing the Okay button

    $listBox->bind('<Double-Button-1>' => $chooseSub);

    $listBox->insert('end', @fList);

    $topLevel->Button(
        -text    => "Okay",
        -command => $chooseSub,
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    $topLevel->Button(
        -text => "Cancel",
        %{ $self->font_settings('gui') },
        -command => sub { destroy $topLevel; }
    )->pack(-side => 'left', -fill => 'both', -expand => 1);
}

sub do_tabs {
    my $self = shift;
    my ($tabs_str);
    my ($w, $result, $tabs_cfg);

    $w = $self->{'main_window'}->DialogBox(-title => "Tabs", -buttons => [qw/Okay Cancel/]);

    $tabs_cfg = $self->{'text'}->cget(-tabs);

    $tabs_str = join " ", @$tabs_cfg if $tabs_cfg;

    $w->add('Label', -text => 'Tabs:', %{ $self->font_settings('gui') })->pack(-side => 'left');

    $w->add('Entry', -textvariable => \$tabs_str, %{ $self->font_settings('code') })
        ->pack(-side => 'left')
        ->selectionRange(0, 'end');

    $result = $w->Show();

    return unless $result eq 'Okay';

    $self->{'text'}->configure(-tabs => [split /\s/, $tabs_str]);
}

sub close_ptkdb_window_and_run {
    my ($self) = @_;
    $self->{'event'}      = 'run';
    $self->{current_file} = q();     # force a file reset
    $self->{'main_window'}->destroy;
    $self->{'main_window'} = undef;
}

sub setup_menu_bar_item_file {
    my ($self) = @_;

    $self->bind_key('open_file',            sub { $self->DoOpen(); });
    $self->bind_key('goto_line',            sub { $self->GotoLine(); });
    $self->bind_key('find_text',            sub { $self->FindText(); });
    $self->bind_key('restart',              sub { $self->DoRestart(); });
    $self->bind_key('quit',                 sub { $self->DoQuit(); });
    $self->bind_key('close_window_and_run', sub { $self->close_ptkdb_window_and_run; });

    my $items = [
        ['command' => 'About...',      -command => sub { $self->DoAbout(); }],
        ['command' => 'Bug Report...', -command => sub { self->DoBugReport(); }],
        "-",

        [   'command'    => 'Open',
            -accelerator => $self->key_accelerator('open_file'),
            -underline   => 0,
            -command     => sub { $self->DoOpen(); }
        ],

        [   'command'  => 'Save Config...',
            -underline => 0,
            -command   => sub { $self->{state_manager}->save_state_callback() },
        ],

        [   'command'  => 'Restore Config...',
            -underline => 0,
            -command   => sub { $self->{state_manager}->restore_state_callback() },
        ],

        [   'command'    => 'Goto Line...',
            -underline   => 0,
            -accelerator => $self->key_accelerator('goto_line'),
            -command     => sub { $self->GotoLine(); },
        ],

        [   'command'    => 'Find Text...',
            -accelerator => $self->key_accelerator('find_text'),
            -underline   => 0,
            -command     => sub { $self->FindText(); }
        ],

        ['command' => "Tabs...", -command => sub { $self->do_tabs(); }],

        "-",

        [   'command'    => 'Close Window and Run',
            -accelerator => $self->key_accelerator('close_window_and_run'),
            -underline   => 6,
            -command     => sub { $self->close_ptkdb_window_and_run(); }
        ],

        [   'command'    => 'Quit...',
            -accelerator => $self->key_accelerator('quit'),
            -underline   => 0,
            -command     => sub { $self->DoQuit(); }
        ]
    ];

    return $items;
}

sub setup_menu_bar_item_control {
    my ($self) = @_;

    my $clearAllBkptsSub = sub {
        $self->removeAllBreakpoints($self->{current_file});
        DB::clear_all_breakpoint_info();
    };

    $self->bind_key('run',               $self->{shared_callbacks}->{runSub});
    $self->bind_key('run_to_here',       $self->{shared_callbacks}->{runToSub});
    $self->bind_key('toggle_breakpoint', sub { $self->SetBreakPoint; });
    $self->bind_key('step_over',         $self->{shared_callbacks}->{stepOverSub});
    $self->bind_key('step_in',           $self->{shared_callbacks}->{stepInSub});
    $self->bind_key('step_out',          $self->{shared_callbacks}->{returnSub});

    my $items = [
        [   'command'    => 'Run',
            -accelerator => $self->key_accelerator('run'),
            -underline   => 0,
            -command     => $self->{shared_callbacks}->{runSub}
        ],
        [   'command'    => 'Run To Here',
            -accelerator => $self->key_accelerator('run_to_here'),
            -underline   => 5,
            -command     => $self->{shared_callbacks}->{runToSub}
        ],
        '-',
        [   'command'    => 'Set Breakpoint',
            -underline   => 4,
            -command     => sub { $self->SetBreakPoint; },
            -accelerator => $self->key_accelerator('toggle_breakpoint')
        ],
        [   'command' => 'Clear Breakpoint',
            -command  => sub { $self->UnsetBreakPoint }
        ],
        [   'command'  => 'Clear All Breakpoints',
            -underline => 6,
            -command   => $clearAllBkptsSub
        ],
        '-',
        [   'command'    => 'Step Over',
            -accelerator => $self->key_accelerator('step_over'),
            -underline   => 0,
            -command     => $self->{shared_callbacks}->{stepOverSub}
        ],
        [   'command'    => 'Step In',
            -accelerator => $self->key_accelerator('step_in'),
            -underline   => 5,
            -command     => $self->{shared_callbacks}->{stepInSub}
        ],
        [   'command'    => 'Return',
            -accelerator => $self->key_accelerator('step_out'),
            -underline   => 3,
            -command     => $self->{shared_callbacks}->{returnSub}
        ],
        '-',
        [   'command'    => 'Restart...',
            -accelerator => $self->key_accelerator('restart'),
            -underline   => 0,
            -command     => sub { $self->DoRestart(); }
        ],
        '-',
        [   'checkbutton' => 'Stop On Warning',
            -variable     => \$self->{stop_on_warning},
            -command      => sub { $self->set_stop_on_warning(); }
        ]

    ];
    return $items;
}

sub setup_menu_bar_item_data {
    my ($self) = @_;

    # Set up the stated accelerators...
    $self->bind_key('enter_expression', sub { $self->enterExpr() });

    # When we were using an Hlist (version 1.1091), <Delete> wasn't mapped and
    # didn't cause any change to the expressions displayed. When we cut over to
    # a Devel::ptkdb::Playlist, the <Delete> key was mapped by
    # Devel::ptkdb::Playlist but it didn't pass back the highlighted entry. The
    # result was an entry that disappeared off the screen, but not from our
    # data structures, so it reappeared after the next line was stepped. So, we
    # are mappping to trap and gracefully handle it.
    $self->{main_window}->bind('<Delete>' => sub { $self->deleteExpr(); });
    $self->bind_key('eval_window', sub { $self->setupEvalWindow(); });

    my $items = [
        [   'command'    => 'Enter Expression',
            -accelerator => $self->key_accelerator('enter_expression'),
            -command     => sub { $self->enterExpr() }
        ],
        [   'command'    => 'Delete Expression',
            -accelerator => 'Delete',
            -command     => sub { $self->deleteExpr() }
        ],
        [   'command' => 'Delete All Expressions',
            -command  => sub {
                $self->deleteAllExprs();
                $self->{'expr_list'} = [];    # clears list by dropping ref to it, replacing it with a new one
            }
        ],
        '-',
        [   'command'    => 'Expression Eval Window...',
            -accelerator => $self->key_accelerator('eval_window'),
            -command     => sub { $self->setupEvalWindow(); }
        ],
    ];

    return $items;
}

sub setup_menu_bar_item_bookmarks {
    my ($self) = @_;

    #
    # "Add bookmark" item
    #
    my $bkMarkSub = sub { $self->add_bookmark(); };

    $self->{'bookmarks_menu'}->command(
        -label   => "Add Bookmark",
        -command => $bkMarkSub
    );

    $self->{'bookmarks_menu'}->command(
        -label   => "Edit Bookmarks",
        -command => sub { $self->edit_bookmarks() }
    );

    $self->{'bookmarks_menu'}->separator();

    #
    # Check to see if there is a bookmarks file
    #
    return unless -e $self->{BookMarksPath} && -r $self->{BookMarksPath};

    use vars qw($ptkdb_bookmarks);
    local ($ptkdb_bookmarks);    # ref to hash of bookmark entries

    do $self->{BookMarksPath};   # eval the file

    $self->add_bookmark_items(@$ptkdb_bookmarks);

}

sub setup_menu_bar_item_windows {
    my ($self) = @_;
    my ($bsub) = sub { $self->{'text'}->focus() };
    my ($csub) = sub { $self->{'quick_entry'}->focus() };
    my ($dsub) = sub { $self->{'entry'}->focus() };

    $self->bind_key('focus_code',       $bsub);
    $self->bind_key('focus_quick_expr', $csub);
    $self->bind_key('focus_expr',       $dsub);

    my $items = [
        [   'command' => 'Code Pane', -accelerator => $self->key_accelerator('focus_code'),
            -command  => $bsub
        ],
        [   'command' => 'Quick Entry', -accelerator => $self->key_accelerator('focus_quick_expr'),
            -command  => $csub
        ],
        [   'command' => 'Expr Entry', -accelerator => $self->key_accelerator('focus_expr'),
            -command  => $dsub
        ]
    ];
    return $items;
}

sub setup_menu_bar {
    my ($self) = @_;
    my $mw = $self->{main_window};

    $self->{menu_bar}
        = $mw->Frame(-relief => 'raised', -borderwidth => '1')->pack(-side => 'top', -fill => 'x');

    my $mb = $self->{menu_bar};

    # File menu
    $self->{file_menu_button} = $mb->Menubutton(
        -text      => 'File',
        -underline => 0,
        -menuitems => $self->setup_menu_bar_item_file(),
        %{ $self->font_settings('gui') },
    )->pack(
        -side =>,
        'left',
        -anchor => 'nw',
        -padx   => 2
    );

    # Control menu
    $self->{control_menu_button} = $mb->Menubutton(
        -text      => 'Control',
        -underline => 0,
        -menuitems => $self->setup_menu_bar_item_control(),
        %{ $self->font_settings('gui') },
    )->pack(
        -side =>,
        'left',
        -padx => 2
    );

    # Data Menu
    $self->{data_menu_button} = $mb->Menubutton(
        -text      => 'Data',
        -menuitems => $self->setup_menu_bar_item_data(),
        -underline => 0,
        %{ $self->font_settings('gui') },
    )->pack(
        -side => 'left',
        -padx => 2
    );

    # Stack menu - list of all current stack frames. Generated on the fly.
    $self->{stack_menu} = $mb->Menubutton(
        -text      => 'Stack',
        -underline => 2,
        %{ $self->font_settings('gui') },
    )->pack(
        -side => 'left',
        -padx => 2
    );

    # Bookmarks menu
    $self->{bookmarks_menu} = $mb->Menubutton(
        -text      => 'Bookmarks',
        -underline => 0,
        %{ $self->font_settings('gui') },
    )->pack(
        -side => 'left',
        -padx => 2
    );
    $self->setup_menu_bar_item_bookmarks();

    # Windows Menu
    $mb->Menubutton(
        -text      => 'Windows',
        -menuitems => $self->setup_menu_bar_item_windows,
        %{ $self->font_settings('gui') },
    )->pack(
        -side => 'left',
        -padx => 2
    );
}

sub setup_button_bar {
    my ($self) = @_;
    my $mw = $self->{main_window};

    #
    # Bar for some popular controls
    #
    $self->{button_bar} = $mw->Frame()->pack(-side => 'top', -fill => 'x');

    $self->{stepin_button} = $self->{button_bar}->Button(
        -text, => "Step In",
        %{ $self->font_settings('gui') },
        -command => $self->{shared_callbacks}->{stepInSub}
    );

    $self->{stepover_button} = $self->{button_bar}->Button(
        -text, => "Step Over",
        %{ $self->font_settings('gui') },
        -command => $self->{shared_callbacks}->{stepOverSub}
    );

    $self->{return_button} = $self->{button_bar}->Button(
        -text, => "Return",
        %{ $self->font_settings('gui') },
        -command => $self->{shared_callbacks}->{returnSub}
    );

    $self->{run_button} = $self->{button_bar}->Button(
        -background => 'green',
        -text,      => "Run",
        %{ $self->font_settings('gui') },
        -command => $self->{shared_callbacks}->{runSub}
    );

    $self->{run_to_button} = $self->{button_bar}->Button(
        -text, => "Run To",
        %{ $self->font_settings('gui') },
        -command => $self->{shared_callbacks}->{runToSub}
    );

    $self->{breakpt_button} = $self->{button_bar}->Button(
        -text, => "Break",
        %{ $self->font_settings('gui') },
        -command => sub { $self->SetBreakPoint; }
    );
    $self->{breakpt_button}->pack(-side => 'right');
    $self->{run_to_button}->pack(-side => 'right');
    $self->{run_button}->pack(-side => 'right');
    $self->{return_button}->pack(-side => 'right');
    $self->{stepover_button}->pack(-side => 'right');
    $self->{stepin_button}->pack(-side => 'right');

    $self->setup_command_line($self->{button_bar});

    push @{ $self->{DisableOnLeave} },
        @$self{
        'stepin_button', 'stepover_button', 'return_button', 'run_button',
        'run_to_button', 'breakpt_button'
        };
}

sub setup_command_line {
    my ($self, $parent) = @_;

    $parent //= $self->{main_window};

    $self->{debugger_command_obj} = Devel::ptkdb::Cmd->new(ptkdb_obj => $self);

    my $frm = $parent->Frame()->pack(
        -side   => 'left',
        -fill   => 'x',
        -expand => 1,
    );

    $frm->Label(
        -text => 'Command:',
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left');

    my $ghost_widget = $frm->Label(
        -text => q{},
        %{ $self->font_settings('gui') },
    )->pack(
        -side => 'left',
        -padx => 4,
    );

    my $entry_widget = $frm->Entry(
        -width => 1,
        %{ $self->font_settings('gui') },
    )->pack(
        -side   => 'left',
        -fill   => 'x',
        -expand => 1,
    );

    $self->{debugger_command_obj}->attach_widget(
        widget       => $entry_widget,
        ghost_widget => $ghost_widget,
    );

    my $run_command = sub {
        my $command = $self->{debugger_command_obj}->command_text();

        $entry_widget->delete(0, 'end');

        $self->{debugger_command_obj}->execute($command);

        $self->focus_debugger_command_widget();
        $self->{debugger_command_obj}->update_ghost();

        return;
    };

    $entry_widget->bind('<Return>' => $run_command);

    $self->{debugger_command_widget} = $entry_widget;
    $self->{debugger_command_obj}->update_ghost();

    return;
}

sub edit_bookmarks {
    my ($self) = @_;

    my ($top) = $self->{main_window}->Toplevel(-title => "Edit Bookmarks");

    my $list
        = $top->Scrolled('Listbox', -selectmode => 'multiple', %{ $self->font_settings('code') })
        ->pack(-side => 'top', -fill => 'both', -expand => 1);
    $self->apply_font_settings($list, 'code');

    my $deleteSub = sub {
        my $cnt = 0;
        for ($list->curselection) {
            $list->delete($_ - $cnt++);
        }
    };

    my $okaySub = sub {
        $self->{'bookmarks'} = [$list->get(0, 'end')];    # replace the bookmarks
    };

    my $frm = $top->Frame()->pack(-side => 'top', -fill => 'x', -expand => 1);

    my $deleteBtn
        = $frm->Button(-text => 'Delete', -command => $deleteSub, %{ $self->font_settings('gui') })
        ->pack(-side => 'left', -fill => 'x', -expand => 1);
    my $cancelBtn = $frm->Button(
        -text => 'Cancel', -command => sub { destroy $top; },
        %{ $self->font_settings('gui') }
    )->pack(-side => 'left', -fill => 'x', -expand => 1);
    my $dismissBtn
        = $frm->Button(-text => 'Okay', -command => $okaySub, %{ $self->font_settings('gui') })
        ->pack(-side => 'left', -fill => 'x', -expand => 1);

    $list->insert('end', @{ $self->{'bookmarks'} });

}

#
# $item = "$fname:$lineno"
#
sub add_bookmark_items {
    my ($self, @items) = @_;
    my ($menu) = ($self->{'bookmarks_menu'});

    $self->{'bookmarks_changed'} = 1;

    for (@items) {
        my $item = $_;
        $menu->command(
            -label   => $_,
            -command => sub { $self->bookmark_cmd($item) }
        );
        push @{ $self->{'bookmarks'} }, $item;
    }
}

#
# Invoked from the "Add Bookmark" command
#
sub add_bookmark {
    my ($self) = @_;

    my $line  = $self->get_lineno();
    my $fname = $self->{'current_file'};
    $self->add_bookmark_items("$fname:$line");

}

#
# Command executed when someone selects
# a bookmark
#
sub bookmark_cmd {
    my ($self, $item) = @_;

    $item =~ /(.*):([0-9]+)$/;

    $self->set_file($1, $2);

}

sub save_bookmarks {
    my ($self, $pathName) = @_;

    eval {
        open my $F, '>', $pathName || die "open failed";
        my $str
            = Data::Dumper->new([$self->{'bookmarks'}], ['ptkdb_bookmarks'])
            ->Indent(2)
            ->$dumpFunc();
        print $F $str || die "Saving bookmarks failed: $!";
        close($F);
    };

    if ($@) {
        $self->do_alert(
            title => 'Bookmarks Error',
            msg   => "$@"
        );
        return;
    }

}

#
# This is our callback from a double click in our Playlist.  A click in an
# expanded item will delete the children beneath it, and the next time it
# updates, it will only update that entry to that depth.  If an item is
# 'unexpanded' such as a hash or a list, it will expand it one more level.  How
# much further an item is expanded is controlled by variable $add_expr_depth.
#
sub expr_expand {
    my $self   = shift;
    my ($path) = @_;
    my $l      = $self->{'data_list'};
    my ($parent, $root, $index, @children, $depth);

    $parent = $path;
    $root   = $path;
    $depth  = 0;

    for ($root = $path; defined $parent && $parent ne q(); $parent = $l->infoParent($root)) {
        $root = $parent;
        $depth += 1;
    }

    # Determine the index of the root of our expression
    $index = 0;
    for (@{ $self->{'expr_list'} }) {
        last if $_->{'expr'} eq $root;
        $index += 1;
    }

    # If we have children we're going to delete them
    @children = $l->infoChildren($path);

    if (scalar @children > 0) {
        $l->deleteOffsprings($path);
        $self->{'expr_list'}->[$index]->{'depth'} = $depth - 1;    # adjust our depth
    } else {
        # Delete the existing tree and insert a new one
        my @code_item_style = $self->code_item_style_args($l);
        $l->deleteEntry($root);
        $l->add($root, -at => $index, @code_item_style);
        $self->{'expr_list'}->[$index]->{'depth'} += $self->{'add_expr_depth'};

        # Force an update on our expressions
        $self->{'event'} = 'update';
    }
}

# This is our callback for moving an entry in the Playlist. Once were
# done moving the item, we refresh our data structure from the widget.

sub expr_move {
    my $self = shift;
    my ($widget, $action, $path, $newIndex) = @_;

    if ($action eq 'done_moving') {
        # Index by the path on screen...
        my %expr_hash = map { $_->{expr}, $_ } @{ $self->{'expr_list'} };

        # ...so we can resort by the screen order...
        $self->{'expr_list'}
            = [grep {defined} map { $expr_hash{$_} } $self->{'data_list'}->infoChildren()];

        # ...and force an update on our expressions, so that after the
        # chosen entry is dropped in its new position, it re-opens to
        # its prior displayed depth
        $self->{'event'} = 'update';
    }
}

sub line_number_from_coord {
    my ($self, $txtWidget, $coord) = @_;
    my ($index);

    $index = $txtWidget->index($coord);

    # index is in the format of lineno.column
    $index =~ /([0-9]*)\.([0-9]*)/o;

    # return a list of (col, line).  Why backwards?
    return ($2, $1);
}

# =============================================================================
# In the following breakpoint functions, $txtWidget and $self are NOT
# erroneously reversed; this is a result of the calling syntax of the text-bind
# callback. DO NOT SWAP THEM!
sub set_breakpoint_tag {
    my ($txtWidget, $self, $coord, $value) = @_;
    my ($idx);

    $idx = $self->line_number_from_coord($txtWidget, $coord);

    $self->insertBreakpoint($self->{'current_file'}, $idx, $value);

}

sub clear_breakpoint_tag {
    my ($txtWidget, $self, $coord) = @_;
    my ($idx);

    $idx = $self->line_number_from_coord($txtWidget, $coord);

    $self->removeBreakpoint($self->{'current_file'}, $idx);

}

sub change_breakpoint_tag {
    my ($txtWidget, $self, $coord, $value) = @_;
    my ($idx, $brkpt, @tagSet);

    $idx = $self->line_number_from_coord($txtWidget, $coord);

    #
    # Change the value of the breakpoint
    #
    @tagSet = ("$idx.0", "$idx.$self->{'linenumber_length'}");

    $brkpt = &DB::get_breakpoint($self->{'current_file'}, $idx + $self->{'line_offset'});
    return unless $brkpt;

    #
    # Check the breakpoint tag
    #
    if ($txtWidget) {
        $txtWidget->tagRemove('breaksetLine',      @tagSet);
        $txtWidget->tagRemove('breakdisabledLine', @tagSet);
    }

    $brkpt->{'value'} = $value;

    if ($txtWidget) {
        if ($brkpt->{'value'}) {
            $txtWidget->tagAdd('breaksetLine', @tagSet);
        } else {
            $txtWidget->tagAdd('breakdisabledLine', @tagSet);
        }
    }

}

sub _sub_list_sort {

    # We want the 'main' namespace to sort to the top because that is script
    # being debugged.
    if ($a eq 'main' and $b eq 'main') {
        return 0;
    } elsif ($a eq 'main') {
        return -1;
    } elsif ($b eq 'main') {
        return 1;
    } else {
        if (    $a =~ m/:\d+\]$/
            and $b =~ m/:\d+\]$/) {
            # This bit sorts entries such as
            #
            # __ANON__[Foo:1443] and __ANON__[Foo:23]
            #
            # in numeric order because the non numeric parts match instead of
            # straight alphbetic, in which case they're backwards.
            my @a  = split(/:/, $a);
            my @b  = split(/:/, $b);
            my $ja = join(':', @a[0 .. scalar(@a) - 2]);
            my $jb = join(':', @b[0 .. scalar(@b) - 2]);
            if ($ja eq $jb) {
                chop $a[-1];
                chop $b[-1];
                return $a[-1] <=> $b[-1];
            }
        }
    }
    return lc($a) cmp lc($b);
}

# Sort the entries case-insensitively, floating the 'main' namespace to the top.
sub sub_list_sort {
    my $summy  = 6;
    my @sorted = sort _sub_list_sort @_;
    return (wantarray ? @sorted : \@sorted);
}

# Callback executed when someone double clicks an entry in the 'Subs'
# Tk::Notebook page.
sub sub_list_cmd {
    my ($self, $path) = @_;
    $path =~ s/\@/::/g;    # Put back the :: we swapped out

    my $sub_info = $DB::sub{$path};
    return unless defined $sub_info;

    return unless $sub_info =~ /(.*):([0-9]+)-[0-9]+$/o;

    $self->set_file($1, $2);    # file name will be in $1, line number will be in $2 */

    return;
}

sub fill_subs_page {
    my ($self) = @_;
    $self->{'sub_list'}->delete('all');    # clear existing entries

    my %tree;
    for my $function (keys %DB::sub) {

        # For function Foo::Bar::Bang, need to add Foo and Foo::Bar
        # before we add Foo::Bar::Bang. We create the parent keys with
        # the split...
        my @leaves = split('::', $function);

        for my $leaf (0 .. @leaves - 1) {
            # ...and build each branch. We told the tree that the
            # separator was '@' because trying to use a compound '::'
            # doesn't work.
            my $branch = join('@', @leaves[0 .. $leaf]);
            $tree{$branch} = $leaves[$leaf];
        }
    }

    # Now that we have the branches, sort and add
    my @entries         = sub_list_sort(keys %tree);
    my @code_item_style = $self->code_item_style_args($self->{sub_list}, 'imagetext');
    for (@entries) {
        $self->{sub_list}->add($_, -text => $tree{$_}, @code_item_style);
        # We want all the nodes closed to start
        $self->{sub_list}->hide(entry => $_) if (split('@', $_) > 1);
    }
    $self->{sub_list}->autosetmode();
}

sub setup_subs_page {
    my ($self) = @_;

    $self->{'subs_page_activated'} = 1;
    $self->{'sub_list'}            = $self->{'subs_page'}->Scrolled(
        'Tree',
        -separator => q(@),
        -command   => sub { $self->sub_list_cmd(@_); },
        %{ $self->font_settings('code') },
    );
    $self->apply_font_settings($self->{'sub_list'}, 'code');

    $self->fill_subs_page();
    $self->{'sub_list'}->pack(
        -side   => 'left',
        -fill   => 'both',
        -expand => 1
    );
    $self->{'subs_list_cnt'} = scalar keys %DB::sub;

}

sub check_search_request {
    my ($entry, $self, $searchButton, $regexBtn) = @_;
    my ($txt) = $entry->get;

    if ($txt =~ /^\s*[0-9]+\s*$/) {
        $self->DoGoto($entry);
        return;
    }

    if ($txt =~ /\.\*/) {    # common regex search pattern
        $self->FindSearch($entry, $regexBtn, 1);
        return;
    }

    # vanilla search
    $self->FindSearch($entry, $searchButton, 0);
}

sub setup_search_panel {
    my ($self, $parent, @packArgs) = @_;
    my ($frm, $srchBtn, $regexBtn, $entry);

    $frm = $parent->Frame();

    $frm->Button(
        -text    => 'Goto',
        -command => sub { $self->DoGoto($entry) },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left');
    $srchBtn = $frm->Button(
        -text    => 'Search',
        -command => sub { $self->FindSearch($entry, $srchBtn, 0); },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left');

    $regexBtn = $frm->Button(
        -text    => 'Regex',
        -command => sub { $self->FindSearch($entry, $regexBtn, 1); },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left',);

    $entry = $frm->Entry(-width => 50, %{ $self->font_settings('code') })
        ->pack(-side => 'left', -fill => 'both', -expand => 1);

    $entry->bind('<Return>', sub { check_search_request($entry, $self, $srchBtn, $regexBtn); });

    $frm->pack(@packArgs);

}

sub setup_breakpts_page {
    my ($self) = @_;

    $self->{'breakpts_page'} = $self->{'notebook'}->add("brkptspage", -label => "BrkPts");

    $self->{'breakpts_table'}
        = $self->{'breakpts_page'}->Table(-columns => 1, -scrollbars => 'se')->pack(
        -side   => 'top',
        -fill   => 'both',
        -expand => 1
        );

    $self->{'breakpts_table_data'} = {};    # controls addressed by "fname:lineno"

}

sub setup_frames {
    my ($self) = @_;
    my $mw = $self->{'main_window'};
    my ($txt, $code_scroller, $place_holder, $frm);

    # get the side that we want to put the code pane on

    my ($codeSide) = $ENV{'PTKDB_CODE_SIDE'} || $mw->optionGet("codeside", q()) || 'left';

    $mw->update;    # force geometry manager to map main_window
    my $half_width = int(($mw->width || $mw->reqwidth) / 2);
    $frm = $mw->Frame(
        -width => $half_width,
    );              # frame for our code pane and search controls

    $self->setup_search_panel($frm, -side => 'top', -fill => 'x');

    #
    # Text window for the code of our currently viewed file
    #
    $code_scroller = $frm->Scrolled(
        'ROText',
        -wrap => "none",
        %{ $self->{'scrollbar_cfg'} },
        %{ $self->font_settings('code') }
    );

    $self->apply_font_settings($code_scroller, 'code');
    $self->{'text'} = $code_scroller;

    for ($code_scroller->children) {
        next unless (ref $_) =~ /ROText$/;
        $self->{'text'} = $_;
        last;
    }
    $txt = $self->{'text'};
    $self->apply_font_settings($txt, 'code');

    for ($self->{'step_over_mouse'}) {
        $txt->bind($_ => sub { $self->{'shared_callbacks'}->{'stepOverSub'}; });
    }

    for ($self->{'step_in_mouse'}) {
        $txt->bind($_ => sub { $self->{'shared_callbacks'}->{'stepInSub'}; });
    }

    for ($self->{'return_mouse'}) {
        $txt->bind($_ => sub { $self->{'shared_callbacks'}->{'returnSub'}; });
    }

    $frm->packPropagate(0);
    $code_scroller->packPropagate(0);

    $frm->packAdjust(-side => $codeSide, -fill => 'both', -expand => 1);
    $code_scroller->pack(-side => 'left', -fill => 'both', -expand => 1);

    $self->configure_text();

    #
    # Notebook
    #
    $self->{'notebook'} = $mw->NoteBook();
    $self->{'notebook'}->configure(
        -width => $half_width,
    );
    $self->{'notebook'}->packPropagate(0);
    $self->{'notebook'}->pack(-side => $codeSide, -fill => 'both', -expand => 1);

    #
    # tab for the data entries
    #
    $self->{'data_page'} = $self->{'notebook'}->add("datapage", -label => "Exprs");

    #
    # frame, entry and label for quick expressions
    #
    my $frame = $self->{'data_page'}->Frame()->pack(-side => 'top', -fill => 'x');
    my $label = $frame->Label(-text => "Quick Expr:", %{ $self->font_settings('gui') })
        ->pack(-side => 'left');
    $self->{'quick_entry'} = $frame->Entry(%{ $self->font_settings('code') })
        ->pack(-side => 'left', -fill => 'x', -expand => 1);
    $self->{'quick_entry'}->bind('<Return>', sub { $self->quickExpr(); });

    #
    # Entry widget for expressions and breakpoints
    #
    $frame = $self->{'data_page'}->Frame()->pack(-side => 'top', -fill => 'x');
    $label = $frame->Label(-text => "Enter Expr:", %{ $self->font_settings('gui') })
        ->pack(-side => 'left');
    $self->{'entry'} = $frame->Entry(%{ $self->font_settings('code') })
        ->pack(-side => 'left', -fill => 'x', -expand => 1);
    $self->{'entry'}->bind('<Return>', sub { $self->enterExpr() });

    #
    # Playlist (HList with drag-n-drop) for data expressions
    #
    $self->{data_list} = $self->{data_page}->Scrolled(
        'Playlist',
        %{ $self->{'scrollbar_cfg'} },
        -separator => $self->{'pathSep'},
        %{ $self->font_settings('code') },
        -command         => sub { $self->expr_expand(@_) },
        -callback_change => sub { $self->expr_move(@_); }
    );
    $self->apply_font_settings($self->{data_list}, 'code');
    $self->{data_list}->pack(-side => 'top', -fill => 'both', -expand => 1);    #

    # tab for code call hierarchy. All modules are presented, including the
    # ones for THIS DEBUGGER. Which means you can debug the debugger while
    # running the debugger. Wow.
    $self->{'subs_page_activated'} = 0;
    $self->{'subs_page'}           = $self->{'notebook'}->add(
        "subspage", -label => "Subs",
        -createcmd => sub { $self->setup_subs_page }
    );

    #
    # breakpoints
    #
    $self->setup_breakpts_page();

}

sub configure_text {
    my ($self) = @_;
    my ($txt, $mw) = ($self->{'text'}, $self->{'main_window'});
    my ($place_holder);

    $self->{'expr_balloon'} = $txt->Balloon();
    # initial expression
    $self->{'balloon_expr'} = ' ';

    $self->{'balloon_dumper'} = new Data::Dumper([$place_holder]);
    $self->{'balloon_dumper'}->Terse(1);
    $self->{'balloon_dumper'}->Indent($self->{'eval_dump_indent'});

    $self->{'quick_dumper'} = new Data::Dumper([$place_holder]);
    $self->{'quick_dumper'}->Terse(1);
    $self->{'quick_dumper'}->Indent(0);

    $self->{'expr_ballon_msg'} = ' ';

    $self->{'expr_balloon'}->attach(
        $txt,
        -initwait        => 300,
        -msg             => \$self->{'expr_ballon_msg'},
        -balloonposition => 'mouse',
        -postcommand     => sub { $self->balloon_post(@_) },
        -motioncommand   => sub { $self->balloon_motion(@_); }
    );

    # tags for the text

    my @stopTagConfig = (
        -foreground => 'white',
        -background => $mw->optionGet("stopcolor", "background")
            || $ENV{'PTKDB_STOP_TAG_COLOR'}
            || 'blue'
    );

    push @stopTagConfig, %{ $self->font_settings('code') };

    $txt->tagConfigure('stoppt', @stopTagConfig);
    $txt->tagConfigure(
        'search_tag',
        "-background" => $mw->optionGet("searchtagcolor", "background") || "green"
    );

    $txt->tagConfigure("breakableLine",    -overstrike => 0);
    $txt->tagConfigure("nonbreakableLine", -overstrike => 1);
    $txt->tagConfigure(
        "breaksetLine",
        -background => $mw->optionGet("breaktagcolor", "background")
            || $ENV{'PTKDB_BRKPT_COLOR'}
            || 'red'
    );
    $txt->tagConfigure(
        "breakdisabledLine",
        -background => $mw->optionGet("disabledbreaktagcolor", "background")
            || $ENV{'PTKDB_DISABLEDBRKPT_COLOR'}
            || 'green'
    );

    $txt->tagBind(
        "breakableLine", '<Button-1>',
        [\&Devel::ptkdb::set_breakpoint_tag, $self, Ev('@'), 1]
    );
    $txt->tagBind(
        "breakableLine", '<Shift-Button-1>',
        [\&Devel::ptkdb::set_breakpoint_tag, $self, Ev('@'), 0]
    );

    $txt->tagBind(
        "breaksetLine", '<Button-1>',
        [\&Devel::ptkdb::clear_breakpoint_tag, $self, Ev('@')]
    );
    $txt->tagBind(
        "breaksetLine", '<Shift-Button-1>',
        [\&Devel::ptkdb::change_breakpoint_tag, $self, Ev('@'), 0]
    );

    $txt->tagBind(
        "breakdisabledLine", '<Button-1>',
        [\&Devel::ptkdb::clear_breakpoint_tag, $self, Ev('@')]
    );
    $txt->tagBind(
        "breakdisabledLine", '<Shift-Button-1>',
        [\&Devel::ptkdb::change_breakpoint_tag, $self, Ev('@'), 1]
    );

}

sub setup_options {
    my ($self) = @_;
    my $mw = $self->{main_window};

    return unless $mw->can('appname');

    $mw->appname("ptkdb");
    $mw->optionAdd("stopcolor"      => 'cyan', 60);
    $mw->optionAdd("breaktag"       => 'red',  60);
    $mw->optionAdd("searchtagcolor" => 'green');

    $mw->optionClear;    #  necessary to reload xresources

}

sub simpleGeo {
    my ($self) = @_;
    my @main_geo = grep {m/[0-9]/} split(/([x+-])/, $self->{main_window}->geometry());
    my $simple_loc
        = (   '+'
            . int($main_geo[2] + ($main_geo[0] * .05)) . '+'
            . int($main_geo[3] + ($main_geo[1] * .05)));
    return ($simple_loc);
}

sub get_entry_text {
    my ($self) = @_;
    return $self->{entry}->get();    # get the text in the entry
}

#
# Clear any text that is in the entry field.  If there
# was any text in that field return it.  If there
# was no text then return any selection that may be active.
#
sub clear_entry_text {
    my ($self) = @_;
    my $str = $self->{'entry'}->get();
    $self->{'entry'}->delete(0, 'end');

    #
    # No String
    # Empty String
    # Or a string that is only whitespace
    #
    if (!$str || $str eq q() || $str =~ /^\s+$/) {
        #
        # If there is no string or the string is just white text
        # Get the text in the selction( if any)
        #
        if ($self->{'text'}->tagRanges('sel')) {    # check to see if 'sel' tag exists (return undef value)
            $str = $self->{'text'}->get("sel.first", "sel.last");    # get the text between the 'first' and 'last' point of the sel (selection) tag
        }
        # If still no text, bring the focus to the entry
        elsif (!$str || $str eq q() || $str =~ /^\s+$/) {
            $self->{'entry'}->focus();
            $str = q();
        }
    }
    #
    # Erase existing text
    #
    return $str;
}

sub brkpt_checkbutton {
    my ($self, $fname, $idx, $brkpt) = @_;
    my ($widg);

    change_breakpoint_tag($self->{'text'}, $self, "$idx.0", $brkpt->{'value'})
        if $fname eq $self->{'current_file'};

}

# Insert a breakpoint control into our breakpoint list.  Returns a handle to
# the control.
#
# Expression, if defined, is to be evaluated at the breakpoint and execution
# stopped if it is non-zero/defined.
#
# If action is defined && True then it will be eval'ed before continuing.
sub insertBreakpoint {
    my ($self, $fname, @brks) = @_;
    my ($btn, $cnt, $item);

    my $offset = DB::debugger_injected_line_offset($fname);

    while (@brks) {
        my ($index, $value, $expression) = splice @brks, 0, 3;    # take args 3 at a time

        my $brkpt = {};
        my $txt   = &DB::get_code_line($fname, $index);
        @$brkpt{ 'type', 'line', 'expr', 'value', 'fname', 'text' }
            = ('user', $index, $expression, $value, $fname, "$txt");

        DB::set_breakpoint($fname, $index + $offset, $brkpt);
        $self->add_brkpt_to_brkpt_page($brkpt);

        next unless $fname eq $self->{'current_file'};

        $self->{'text'}
            ->tagRemove("breakableLine", "$index.0", "$index.$self->{'linenumber_length'}");
        $self->{'text'}->tagAdd(
            $value ? "breaksetLine" : "breakdisabledLine",
            "$index.0", "$index.$self->{'linenumber_length'}"
        );
    }
}

sub add_brkpt_to_brkpt_page {
    my ($self, $brkpt) = @_;
    my ($btn,  $fname,   $index, $frm, $upperFrame, $lowerFrame);
    my ($row,  $btnName, $width);

    #
    # Add the breakpoint to the breakpoints page
    #
    ($fname, $index) = @$brkpt{ 'fname', 'line' };
    return if exists $self->{'breakpts_table_data'}->{"$fname:$index"};
    $self->{'brkpt_cnt'} += 1;

    $btnName = $fname;
    $btnName =~ s/.*\/([^\/]*)$/$1/o;

    # Take the last leaf of the pathname.
    $frm        = $self->{'breakpts_table'}->Frame(-relief => 'raised');
    $upperFrame = $frm->Frame()->pack(-side => 'top', '-fill' => 'x', -expand => 1);

    $btn = $upperFrame->Checkbutton(
        -text => "$btnName:$index",
        # CAUTION value tracking
        -variable => \$brkpt->{'value'},
        -command  => sub { $self->brkpt_checkbutton($fname, $index, $brkpt) },
        %{ $self->font_settings('code') },
    );
    $btn->pack(-side => 'left');

    $btn = $upperFrame->Button(
        -text    => "Delete",
        -command => sub { $self->removeBreakpoint($fname, $index); },
        %{ $self->font_settings('gui') },
    );
    $btn->pack(-side => 'left', -fill => 'x', -expand => 1);

    $btn = $upperFrame->Button(
        -text    => "Goto",
        -command => sub { $self->set_file($fname, $index); },
        %{ $self->font_settings('gui') },
    );
    $btn->pack(-side => 'left', -fill => 'x', -expand => 1);

    $lowerFrame = $frm->Frame()->pack(-side => 'top', '-fill' => 'x', -expand => 1);
    $lowerFrame->Label(-text => "Cond:", %{ $self->font_settings('gui') })->pack(-side => 'left');

    $btn
        = $lowerFrame->Entry(-textvariable => \$brkpt->{'expr'}, %{ $self->font_settings('code') });
    $btn->pack(-side => 'left', -fill => 'x', -expand => 1);

    $frm->pack(-side => 'top', -fill => 'x', -expand => 1);

    $row = pop @{ $self->{'brkpt_slots'} } or $row = $self->{'brkpt_cnt'};

    $self->{'breakpts_table'}->put($row, 1, $frm);

    $self->{'breakpts_table_data'}->{"$fname:$index"}->{'frm'} = $frm;
    $self->{'breakpts_table_data'}->{"$fname:$index"}->{'row'} = $row;

    $self->{'main_window'}->update;

    $width = $frm->width;

    if ($width > $self->{'breakpts_table'}->width) {
        $self->{'notebook'}->configure(-width => $width);
    }
}

sub remove_brkpt_from_brkpt_page {
    my ($self, $fname, $idx) = @_;
    my ($table);

    $table = $self->{'breakpts_table'};

    # Delete the breakpoint control in the breakpoints window
    $table->put($self->{'breakpts_table_data'}->{"$fname:$idx"}->{'row'}, 1);    # delete?

    # Add this now empty slot to the list of ones we have open
    push @{ $self->{'brkpt_slots'} }, $self->{'breakpts_table_data'}->{"$fname:$idx"}->{'row'};
    $self->{'brkpt_slots'} = [sort { $b <=> $a } @{ $self->{'brkpt_slots'} }];
    delete $self->{'breakpts_table_data'}->{"$fname:$idx"};
    $self->{'brkpt_cnt'} -= 1;
}

#
# Supporting the "Run To Here..." command
#
sub insertTempBreakpoint {
    my ($self, $fname, $index) = @_;

    my $offset = DB::debugger_injected_line_offset($fname);
    return if (&DB::get_breakpoint($fname, $index + $offset));    # we already have a breakpoint here
    &DB::set_breakpoint(
        $fname, $index + $offset,
        { 'type' => 'temp', 'line' => $index, 'value' => 1 }
    );
}

sub reinsertBreakpoints {
    my ($self, $fname) = @_;

    for my $brkpt (&DB::get_breakpoints($fname)) {
        # Our breakpoints are indexed by line therefore we can have 'gaps'
        # where there lines, but not breaks set for them.
        next unless defined $brkpt;
        $self->insertBreakpoint($fname, @$brkpt{qw(line value expr)})
            if ($brkpt->{'type'} eq 'user');
        $self->insertTempBreakpoint($fname, $brkpt->{line}) if ($brkpt->{'type'} eq 'temp');
    }
}

sub removeBreakpointTags {
    my ($self, @brkpts) = @_;
    my ($idx);

    for my $brkpt (@brkpts) {
        $idx = $brkpt->{'line'};
        $self->{text}->tagRemove(
            ($brkpt->{value} ? 'breaksetLine' : 'breakdisabledLine'),
            "$idx.0", "$idx.$self->{'linenumber_length'}"
        );
        $self->{'text'}->tagAdd("breakableLine", "$idx.0", "$idx.$self->{'linenumber_length'}");
    }
}

#
# Remove a breakpoint from the current window
#
sub removeBreakpoint {
    my ($self, $fname, @idx) = @_;
    my ($chkIdx, $i, $j, $info);

    my $offset = DB::debugger_injected_line_offset($fname);

    for my $idx (@idx) {
        next unless defined $idx;
        my $brkpt = &DB::get_breakpoint($fname, $idx + $offset);
        next unless $brkpt;    # if we do not have an entry

        DB::clear_breakpoint_info($fname, $idx + $offset);
        $self->remove_brkpt_from_brkpt_page($fname, $idx);
        # if this isn't our current file there will be no controls
        next unless $brkpt->{fname} eq $self->{'current_file'};

        # Delete the ext associated with the breakpoint expression (if any)
        $self->removeBreakpointTags($brkpt);
    }
    return;
}

sub removeAllBreakpoints {
    my ($self, $fname) = @_;
    $self->removeBreakpoint($fname, &DB::get_breakpoint_indexes($fname));
}

#
# Delete expressions prior to an update
#
sub deleteAllExprs {
    my ($self) = @_;
    $self->{'data_list'}->delete('all');
}

sub enterExpr {
    my ($self) = @_;
    my $str = $self->clear_entry_text();
    if ($str && $str ne q() && $str !~ /^\s+$/) {    # if there is an expression and it's more than white space
        $self->{'expr'}  = $str;
        $self->{'event'} = 'expr';
    }
}

sub quickExpr {
    my ($self) = @_;

    my $str = $self->{'quick_entry'}->get();

    if ($str && $str ne q() && $str !~ /^\s+$/) {    # if there is an expression and it's more than white space
        $self->{'qexpr'} = $str;
        $self->{'event'} = 'qexpr';
    }
}

sub deleteExpr {
    my ($self) = @_;
    my ($i, @indexes);

    # There are the highlighted entries, the ones we want to
    # delete. You can select more than one contiguous entry.
    my @selectedList = $self->{'data_list'}->info('select');

    # These are the highlighted entries that are actually deleteable;
    # you cannot remove members of a hash or elements of an array.
    my @verifiedList;

    # Our list of all expressions. If any are arrays or hashes, we
    # only have the top-level expression, not any sub-expressions.
    my @exprList = @{ $self->{expr_list} };

    # Key search and delete is quicker than comparisons in multiple
    # loops over multiples arrays below.
    my $exprIdx  = 0;
    my %exprHash = map { $_->{expr} => $exprIdx++ } @exprList;

    # We have to make sure that each selection is not part of a data
    # structure; if a particular key/value of a hash or a member of
    # an array was highlighted (either explicitly or because its top
    # level entry was expanded and selected over while grabbing more
    # than one expression), we have to skip over it.
    foreach my $entry (@selectedList) {
        next if (not exists($exprHash{$entry}));    # TODO - 2014/03/10 - status message here?
        delete $exprHash{$entry};                   # We are deleting the entry here...
        push @verifiedList, $entry;
    }

    if (@verifiedList) {
        # ...so all that's left in %exprHash here are the entries we want
        # to keep and, conveniently, their index values, useful for a
        # slicing operation.
        @exprList = @exprList[sort { $a <=> $b } values(%exprHash)];
        $self->{expr_list} = \@exprList;

        # Now update the widget.
        for (@verifiedList) {
            $self->{data_list}->delete('entry', $_);
        }
    }
}

sub fixExprPath {
    my $self = shift;
    my (@pathList) = @_;
    for (@pathList) {
        s/$self->{'pathSep'}/$self->{'pathSepReplacement'}/go;
    }
    return wantarray ? @pathList : $pathList[0];
}

# Inserts an expression($theRef) into an HList Widget($dl).  If the expression
# is an array, blessed array, hash, or blessed hash(typical object), then this
# routine is called recursively, adding the members to the next level of
# heirarchy, prefixing array members with a [idx] and the hash members with the
# key name.  This continues until the entire expression is decomposed to it's
# atomic constituents.  Protection is given(with $reusedRefs) to ensure that
# 'circular' references within arrays or hashes resolve(i.e. where a member of
# a array or hash contains a reference to a parent element within the
# hierarchy). Returns 1 if sucessfully added 0 if not.
sub insertExpr {
    my ($self, $reusedRefs, $dl, $theRef, $name, $depth, $dirPath) = @_;
    my ($label, $type, $result, $selfCnt, @circRefs);
    my @code_item_style = $self->code_item_style_args($dl);

    #
    # Add data new data entries to the bottom
    #
    $dirPath = q() unless defined $dirPath;

    $label   = q();
    $selfCnt = 0;

    while (ref $theRef eq 'SCALAR') {
        $theRef = $$theRef;
    }
    REF_CHECK: for (;;) {
        push @circRefs, $theRef;
        ## TODO: replace ref and string comps with Ref::Util
        $type = ref $theRef;
        last unless ($type eq "REF");
        $theRef = $$theRef;    # dref again

        $label .= "\\";        # append a
        if (grep $_ == $theRef, @circRefs) {
            $label .= "(circular)";
            last;
        }
    }

    if (!$type || $type eq q() || $type eq "GLOB" || $type eq "CODE") {
        eval {
            if (!defined $theRef) {
                $dl->add($dirPath . $name, -text => "$name = $label" . "undef", @code_item_style);
            } else {
                $dl->add($dirPath . $name, -text => "$name = $label$theRef", @code_item_style);
            }
        };
        my $error = $@;
        if ($error) {
            $self->do_alert(msg => $@);
            return 0;
        }
        return 1;
    }

    if ($type eq 'ARRAY' or "$theRef" =~ /ARRAY/) {
        my ($idx);
        $idx = 0;
        eval { $dl->add($dirPath . $name, -text => "$name = $theRef", @code_item_style); };
        my $error = $@;
        if ($error) {
            $self->do_alert(msg => "$@");
            return 0;
        }
        $result = 1;
        for my $r (@{$theRef}) {

            if (grep $_ == $r, @$reusedRefs) {    # check to make sure that we're not doing a single level self reference
                eval {
                    $dl->add(
                              $dirPath
                            . $self->fixExprPath($name)
                            . $self->{'pathSep'}
                            . "__ptkdb_self_path"
                            . $selfCnt++,
                        -text => "[$idx] = $r REUSED ADDR",
                        @code_item_style
                    );
                };
                $self->do_alert(msg => "$@") if ($@);
                next;
            }

            push @$reusedRefs, $r;
            $result = $self->insertExpr(
                $reusedRefs, $dl, $r, "[$idx]", $depth - 1,
                $dirPath . $self->fixExprPath($name) . $self->{'pathSep'}
            ) unless $depth == 0;
            pop @$reusedRefs;

            return 0 unless $result;
            $idx += 1;
        }
        return 1;
    }

    if ("$theRef" !~ /HASH\050\060x[0-9a-f]*\051/o) {
        eval {
            $dl->add(
                $dirPath . $self->fixExprPath($name), -text => "$name = $theRef",
                @code_item_style
            );
        };
        my $error = $@;
        if ($error) {
            $self->do_alert(msg => "$@");
            return 0;
        }
        return 1;
    }

    # Anything else at this point is either a 'HASH' or an object of some kind.
    my (@theKeys, $idx);
    $idx     = 0;
    @theKeys = sort keys %{$theRef};
    $dl->add($dirPath . $name, -text => "$name = " . "$theRef", @code_item_style);
    $result = 1;

    my %builtins = (
        SCALAR  => 1,
        ARRAY   => 1,
        HASH    => 1,
        CODE    => 1,
        REF     => 1,
        GLOB    => 1,
        LVALUE  => 1,
        FORMAT  => 1,
        IO      => 1,
        VSTRING => 1,
        Regexp  => 1
    );

    for my $r (@$theRef{@theKeys}) {
        if (grep { ($builtins{ ref($_) } ? $_ : \$_) eq ($builtins{ ref($r) } ? $r : \$r) }
            @{$reusedRefs}) {
            # check to make sure that we're not doing a single level self reference
            eval {
                $dl->add(
                          $dirPath
                        . $self->fixExprPath($name)
                        . $self->{'pathSep'}
                        . "__ptkdb_self_path"
                        . $selfCnt++,
                    -text => "$theKeys[$idx++] = $r REUSED ADDR",
                    @code_item_style
                );
            };
            console_say("Inserting expressions, encountered bad path $@") if ($@);
            next;
        }

        push @$reusedRefs, $r;
        $result = $self->insertExpr(
            $reusedRefs,                             # recursion protection
            $dl,                                     # data list widget
            $r,                                      # reference whose value is displayed
            $theKeys[$idx],                          # name
            $depth - 1,                              # remaining expansion depth
            $dirPath . $name . $self->{'pathSep'}    # path to add to
        ) unless $depth == 0;

        pop @{$reusedRefs};
        return 0 unless $result;
        $idx += 1;
    }
    return 1;
}

# We're setting the line where we are stopped.
# Create a tag for this and set it as bold.
sub set_line {
    my ($self, $lineno) = @_;
    my $text = $self->{'text'};

    return if ($lineno <= 0);

    if ($self->{current_line} > 0) {
        $text->tagRemove(
            'stoppt',
            "$self->{current_line}.0 linestart",
            "$self->{current_line}.0 lineend"
        );
    }
    $self->{current_line} = $lineno - $self->{'line_offset'};
    $text->tagAdd(
        'stoppt',
        "$self->{current_line}.0 linestart",
        "$self->{current_line}.0 lineend"
    );
    $self->{'text'}->see("$self->{current_line}.0 linestart");
}

# Set the file that is in the code window.
#
# $fname the 'new' file to view
# $line the line number we're at
# $brkpts any breakpoints that may have been set in this file

sub set_file {
    my ($self,    $fname, $line) = @_;
    my ($lineStr, $text,  $i, @text, $noCode, $title);
    my (@breakableTagList, @nonBreakableTagList);

    return unless $fname;    # We're getting an undef here on 'Restart'.

    my $lines = DB::get_code_lines($fname);
    return unless $lines;

    my $offset = DB::debugger_injected_line_offset($fname);
    $self->{'line_offset'} = $offset;

    $text = $self->{'text'};

    if ($fname eq $self->{current_file}) {
        $self->set_line($line);
        return;
    }

    $title = $fname;      # removing the - messes up stashes on -e invocations
    $title =~ s/^\-//;    # Tk does not like leadiing '-'s
    $self->{main_window}->configure('-title' => $title);

    # Erase any existing text
    $text->delete('0.0', 'end');
    my $len = $self->{'linenumber_length'};

    # This is the tightest loop we have in the ptkdb code.  It is here where
    # performance is the most critical.  The map block formats perl code for
    # display.  Since the file could be potentially large, we will try to make
    # this loop as thin as possible.

    # NOTE: For a new perl individual this may appear as if it was
    # intentionally obfuscated.  This is not not the case.  The following code
    # is the result of an intensive effort to optimize this code.  Prior
    # versions of this code were quite easier to read, but took 3 times longer.

    $lineStr = " " x 200;                          # pre-allocate space for $lineStr
    $i       = 1;
    $noCode  = ($#{$lines} - ($offset + 1)) < 0;

    # The 'map' call will build list of 'string', 'tag' pairs that will become
    # arguments to the 'insert' call.  Passing the text to insert "all at once"
    # rather than one insert->('end', 'string', 'tag') call at time provides a
    # MASSIVE savings in execution time.
    $text->insert(
        'end',
        map {
            # Build collections of tags representing the line numbers for
            # breakable and non-breakable lines.  We apply these tags after
            # we've built the text.
            my $is_breakable = defined($_) && $_ != 0;
            my $code_line    = $_ // q{};

            if ($is_breakable) {
                push @breakableTagList, "$i.0", "$i.$len";
            } else {
                push @nonBreakableTagList, "$i.0", "$i.$len";
            }

            # line number + text of the line
            $lineStr = sprintf($self->{'linenumber_format'}, $i++) . $code_line;

            # removes the CR from win32 instances
            substr $lineStr, -2, 1, '' if $isWin32;

            # append a \n if there isn't one already
            $lineStr .= "\n" unless $code_line =~ /\n$/o;

            # return value for block, a string,tag pair for text insert
            ($lineStr, 'code');

        } @{$lines}[$offset + 1 .. $#{$lines}]
    ) unless $noCode;

    # Apply the tags that we've collected. NOTE: it was attempted to
    # incorporate these operations into the 'map' block above, but that
    # actually degraded performance.

    # apply tag to line numbers where the lines are breakable
    $text->tagAdd("breakableLine", @breakableTagList) if @breakableTagList;
    # apply tag to line numbers where the lines are not breakable.
    $text->tagAdd("nonbreakableLine", @nonBreakableTagList) if @nonBreakableTagList;

    # Reinsert breakpoints (if info provided)
    $self->set_line($line);
    $self->{current_file} = $fname;
    return $self->reinsertBreakpoints($fname);
}

#
# Get the current line that the insert cursor is in
#
sub get_lineno {
    my ($self) = @_;
    my ($info);

    $info = $self->{'text'}->index('insert');    # get the location for the insertion point
    $info =~ s/\..*$/\.0/;
    return int $info;
}

sub page_code_window {
    my ($self) = @_;

    my $text = $self->{text};

    my $current_line = $self->get_lineno();

    my ($top_line)    = split /\./, $text->index('@0,0');
    my ($bottom_line) = split /\./, $text->index('@0,' . ($text->height - 1));

    my $visible_lines = $bottom_line - $top_line + 1;
    my $delta         = int($visible_lines / 3) || 1;

    my $target_line = $current_line + $delta;

    $text->see("$target_line.0");
    $text->markSet('insert', "$target_line.0");

    return 1;
}

sub goto_code_line {
    my ($self, $line) = @_;
    return unless defined $line;

    $line =~ s/^\s+|\s+$//g;
    return unless $line =~ /^\d+$/;

    my $text_line = $line - $self->{'line_offset'};

    return if $text_line < 1;

    $self->{'text'}->see("$text_line.0");
    $self->{'text'}->markSet('insert', "$text_line.0");

    return 1;
}

sub DoGoto {
    my ($self, $entry) = @_;

    my $txt = $entry->get();

    $txt =~ s/(\d*).*/$1/;    # take the first blob of digits

=for reworked

    if ( $txt eq q() ) {
        consoleSay('Invalid line number.');
        return if $txt eq q(); ##>>>>> returns if value unconditionally or return unknown if cpondition true
    }

=cut

    unless ($self->goto_code_line($txt)) {
        print "invalid text range\n";
        return if $txt eq q();
    }
    $self->{'text'}->see("$txt.0");
    $entry->selectionRange(0, 'end') if $entry->can('selectionRange');
}

sub GotoLine {
    my ($self) = @_;

    if ($self->{goto_window}) {
        $self->{goto_window}->raise();
        $self->{goto_text}->focus();
        return;
    }

    #
    # Construct a dialog that has an
    # entry field, okay and cancel buttons
    #
    my $okaySub  = sub { $self->DoGoto($self->{'goto_text'}) };
    my $topLevel = $self->{main_window}->Toplevel(-title => "Goto Line?", -overanchor => 'cursor');
    $self->{goto_text} = $topLevel->Entry(%{ $self->font_settings('code') })
        ->pack(-side => 'top', -fill => 'both', -expand => 1);
    $self->{goto_text}->bind('<Return>', $okaySub);    # make a CR do the same thing as pressing an okay
    $self->{goto_text}->focus();

    # Bind a double click on the mouse button to the same action
    # as pressing the Okay button
    $topLevel->Button(
        -text    => "Okay",
        -command => $okaySub,
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    #
    # Subroutone called when the 'Dismiss'
    # button is pushed.
    #
    my $dismissSub = sub {
        delete $self->{goto_text};
        destroy { $self->{goto_window} };
        delete $self->{goto_window};    # remove the entry from our hash so we won't
    };

    $topLevel->Button(
        -text => "Dismiss",
        %{ $self->font_settings('gui') },
        -command => $dismissSub
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    $topLevel->protocol('WM_DELETE_WINDOW', sub { destroy $topLevel; });
    $topLevel->geometry($self->simpleGeo());
    $self->{goto_window} = $topLevel;

}

#
# Subroutine called when the 'okay' button is pressed
#
sub FindSearch {
    my ($self, $entry, $btn, $regExp) = @_;
    my (@switches, $result);
    my $txt = $entry->get();

    return if $txt eq q();

    push @switches, "-forward"  if $self->{fwdOrBack} eq "forward";
    push @switches, "-backward" if $self->{fwdOrBack} eq "backward";

    if ($regExp) {
        push @switches, "-regexp";
    } else {
        # if we're not doing regex we may as well do caseless search
        push @switches, "-nocase";
    }

    $result = $self->{'text'}->search(@switches, $txt, $self->{search_start});

    # untag the previously found text
    $self->{'text'}->tagRemove('search_tag', @{ $self->{search_tag} })
        if defined $self->{search_tag};

    if (!$result || $result eq q()) {
        # No text was found
        $btn->flash();
        $btn->bell();
        delete $self->{search_tag};
        $self->{'search_start'} = '0.0';
    } else {    # text found
        $self->{'text'}->see($result);
        # set the insertion of the text as well
        $self->{'text'}->markSet('insert' => $result);
        my $len = length $txt;

        if ($self->{fwdOrBack}) {
            $self->{search_start} = "$result +$len chars";
            $self->{search_tag}   = [$result, $self->{search_start}];
        } else {
            # backwards search
            $self->{search_start} = "$result -$len chars";
            $self->{search_tag}   = [$result, "$result +$len chars"];
        }

        # tag the newly found text
        $self->{'text'}->tagAdd('search_tag', @{ $self->{search_tag} });
    }

    $entry->selectionRange(0, 'end') if $entry->can('selectionRange');

}

#
# Support for the Find Text... Menu command
#
sub FindText {
    my ($self) = @_;
    my ($top, $entry, $rad1, $rad2, $chk, $regExp, $frm, $okayBtn);

    # If we already have the Find Text Window open don't bother opening
    # another, bring the existing one to the front.
    if ($self->{find_window}) {
        $self->{find_window}->raise();
        $self->{find_text}->focus();
        return;
    }

    ## WARNING: The KCG code had q( ).
    $self->{search_start} = $self->{'text'}->index('insert') if ($self->{search_start} eq q());

    #
    # Subroutine called when the 'Dismiss' button
    # is pushed.
    #
    my $dismissSub = sub {
        $self->{'text'}->tagRemove('search_tag', @{ $self->{search_tag} })
            if defined $self->{search_tag};
        $self->{search_start} = q();
        destroy { $self->{find_window} };
        delete $self->{search_tag};
        delete $self->{find_window};
    };

    # Construct a dialog that has an entry field, forward, backward, regex
    # option, okay and cancel buttons
    $top = $self->{main_window}->Toplevel(-title => "Find Text?");
    $self->{find_text} = $top->Entry(%{ $self->font_settings('code') })
        ->pack(-side => 'top', -fill => 'both', -expand => 1);
    $frm = $top->Frame()->pack(-side => 'top', -fill => 'both', -expand => 1);

    $self->{fwdOrBack} = 'forward';
    $rad1 = $frm->Radiobutton(
        -text     => "Forward",
        -value    => 1,
        -variable => \$self->{fwdOrBack},
        %{ $self->font_settings('gui') },
    );
    $rad1->pack(-side => 'left', -fill => 'both', -expand => 1);

    $rad2 = $frm->Radiobutton(
        -text     => "Backward",
        -value    => 0,
        -variable => \$self->{fwdOrBack},
        %{ $self->font_settings('gui') },
    );
    $rad2->pack(-side => 'left', -fill => 'both', -expand => 1);

    $regExp = 0;
    $chk    = $frm->Checkbutton(
        -text => "RegExp", -variable => \$regExp,
        %{ $self->font_settings('gui') }
    );
    $chk->pack(-side => 'left', -fill => 'both', -expand => 1);

    # Okay and cancel buttons

    # Bind a double click on the mouse button to the same action
    # as pressing the Okay button
    $okayBtn = $top->Button(
        -text    => "Okay",
        -command => sub { $self->FindSearch($self->{find_text}, $okayBtn, $regExp); },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left', -fill => 'both', -expand => 1);
    $self->{find_text}
        ->bind('<Return>', sub { $self->FindSearch($self->{find_text}, $okayBtn, $regExp); });

    $top->Button(
        -text => "Dismiss",
        %{ $self->font_settings('gui') },
        -command => $dismissSub
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    $top->protocol('WM_DELETE_WINDOW', $dismissSub);
    $top->geometry($self->simpleGeo());
    $self->{find_text}->focus();
    $self->{find_window} = $top;
}

sub main_loop {
    my ($self) = @_;
    my ($evt, $str, $result);
    my $i = 0;
    SWITCH: for ($self->{'event'} = 'null';; $self->{'event'} = undef) {

        Tk::DoOneEvent(0);
        next unless $self->{'event'};

        $evt = $self->{'event'};
        $evt =~ /step/o        && do { last SWITCH; };
        $evt =~ /null/o        && do { next SWITCH; };
        $evt =~ /run/o         && do { last SWITCH; };
        $evt =~ /quit/o        && do { $self->DoQuit; };
        $evt =~ /expr/o        && do { return $evt; };     # adds an expression to our expression window
        $evt =~ /qexpr/o       && do { return $evt; };     # does a 'quick' expression
        $evt =~ /update/o      && do { return $evt; };     # forces an update on our expression window
        $evt =~ /reeval/o      && do { return $evt; };     # updated the open expression eval window
        $evt =~ /balloon_eval/ && do { return $evt };
    }
    return $evt;
}

#
# $subStackRef - A reference to the current subroutine stack
#
sub goto_sub_from_stack {
    my ($self, $f, $lineno) = @_;
    $self->set_file($f, $lineno);
}

sub refresh_stack_menu {
    my ($self) = @_;
    my ($str, $name, $i, $sub_offset, $subStack);

    # CAUTION: In the effort to 'rationalize' the code, we are moving some of
    # this function down over from DB::DB to here.  $sub_offset represents how
    # far 'down' we are from DB::DB.  The $DB::subroutine_depth is tracked in
    # such a way that while we are 'in' the debugger it will not be
    # incremented, and thus represents the stack depth of the target program.
    $sub_offset = 1;
    $subStack   = [];

    # clear existing entries
    for ($i = 0; $i <= $DB::subroutine_depth; $i++) {
        my ($package, $filename, $line, $subName) = caller $i + $sub_offset;
        last if !$subName;
        push @$subStack,
            { 'name' => $subName, 'pck' => $package, 'filename' => $filename, 'line' => $line };
    }

    $self->{stack_menu}->menu->delete(0, 'last');    # delete existing menu items

    for ($i = 0; $subStack->[$i]; $i++) {
        $str = defined $subStack->[$i + 1] ? "$subStack->[$i+1]->{name}" : "MAIN";
        # make copies of the values for use in 'sub'
        my ($f, $line) = ($subStack->[$i]->{filename}, $subStack->[$i]->{line});
        $self->{stack_menu}
            ->command(-label => $str, -command => sub { $self->goto_sub_from_stack($f, $line); });
    }
}

sub get_state {
    my ($self, $fname) = @_;
    my ($val);
    our ($files, $expr_list, $eval_saved_text, $main_win_geometry);

    do "$fname";
    my $error = $@;
    if ($error) {
        $self->do_alert(msg => $@);
        return (undef) x 4;    # return a list of 4 undefined values
    }

    return ($files, $expr_list, $eval_saved_text, $main_win_geometry);
}

sub updateEvalWindow {
    my ($self, @result) = @_;
    my ($leng, $str, $d);

    $leng = 0;
    for (@result) {
        if ($self->{hexdump_evals}) {
            $self->{eval_results}->insert('end', hexDump($_));
        } else {
            $str
                = Data::Dumper->new([$_])
                ->Indent($self->{'eval_dump_indent'})
                ->Terse(1)
                ->$dumpFunc();
        }
        $leng += length $str;
        $self->{eval_results}->insert('end', $str);
    }
}

#
# converts non printable chars to '.' for a string
#
sub printablestr {
    return join q(), map { (ord($_) >= 32 && ord($_) < 127) ? $_ : '.' } split //, $_[0];
}

#
# hex dump utility function
#
sub hexDump {
    my (@retList);
    my ($width) = 8;
    my ($offset);
    my ($len, $fmt, $n, @elems);

    for (@_) {
        my ($str);
        $len = length $_;

        while ($len) {
            $n     = $len >= $width ? $width : $len;
            $fmt   = "\n%04X  " . ("%02X " x $n) . ('   ' x ($width - $n)) . " %s";
            @elems = map ord, split //, (substr $_, $offset, $n);
            $str .= sprintf($fmt, $offset, @elems, printablestr(substr $_, $offset, $n));
            $offset += $width;
            $len    -= $n;
        }
        push @retList, $str;
    }
    return wantarray ? @retList : $retList[0];
}

sub setupEvalWindow {
    my ($self) = @_;
    my ($top, $dismissSub);
    my $f;
    $self->{eval_window}->focus(), return if exists $self->{eval_window};    # already running this window?

    $top                 = $self->{main_window}->Toplevel(-title => "Evaluate Expressions...");
    $self->{eval_window} = $top;
    $self->{eval_text}   = $top->Scrolled(
        'TextUndo',
        %{ $self->{'scrollbar_cfg'} },
        %{ $self->font_settings('code') },
        width  => 50,
        height => 10,
        -wrap  => "none",
    )->packAdjust(-side => 'top', -fill => 'both', -expand => 1);

    $self->{eval_text}->insert('end', $self->{eval_saved_text})
        if exists $self->{eval_saved_text} && defined $self->{eval_saved_text};

    $top->Label(-text, "Results:", %{ $self->font_settings('gui') })
        ->pack(-side => 'top', -fill => 'both', -expand => 'n');

    $self->{eval_results} = $top->Scrolled(
        'Text',
        %{ $self->{'scrollbar_cfg'} },
        width  => 50,
        height => 10,
        -wrap  => "none",
        %{ $self->font_settings('code') }
    )->pack(-side => 'top', -fill => 'both', -expand => 1);

    my $btn = $top->Button(
        -text    => 'Eval...',
        -command => sub {
            $self->{event} = 'reeval';
        },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left', -fill => 'x', -expand => 1);

    $dismissSub = sub {
        $self->{eval_saved_text} = $self->{eval_text}->get('0.0', 'end');
        $self->{eval_window}->destroy;
        delete $self->{eval_window};
    };

    $top->protocol('WM_DELETE_WINDOW', $dismissSub);

    $top->Button(
        -text    => 'Clear Eval',
        -command => sub { $self->{eval_text}->delete('0.0', 'end') },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left', -fill => 'x', -expand => 1);

    $top->Button(
        -text    => 'Clear Results',
        -command => sub { $self->{eval_results}->delete('0.0', 'end') },
        %{ $self->font_settings('gui') },
    )->pack(-side => 'left', -fill => 'x', -expand => 1);

    $top->Button(-text => 'Dismiss', -command => $dismissSub, %{ $self->font_settings('gui') })
        ->pack(-side => 'left', -fill => 'x', -expand => 1);
    $top->Checkbutton(
        -text => 'Hex', -variable => \$self->{hexdump_evals},
        %{ $self->font_settings('gui') }
    )->pack(-side => 'left');
    $top->geometry($self->simpleGeo());
}

sub filterBreakPts {
    my ($breakPtsListRef, $fname) = @_;

    my $lines = DB::get_code_lines($fname);
    return unless $lines;

    #
    # Go through the list of breaks and take out any that
    # are no longer breakable
    #
    for (@$breakPtsListRef) {
        next unless defined $_;
        my $line = $_->{line};
        next if defined $lines->[$line] && $lines->[$line] ne '0';    # still breakable
        $_ = undef;
    }
}

sub DoAbout {
    my $self         = shift;
    my $threadString = q();
    $threadString = "Threads Available" if $Config::Config{usethreads};
    {
        no warnings 'once';
        $threadString = " Thread Debugging Enabled" if $DB::usethreads;
    }

    my $msg = <<"EOSTRING";
ptkdb $DB::VERSION
Copyright 1998,2013 by Andrew E. Page
Copyright 2026 by Matthew O. Persico

Feedback to matthew.persicom+cpan\@gmail.com

This program is free software; you can redistribute it and/or modify
it under the terms of either:

- the GNU General Public License as published by the Free Software
Foundation; either version 1, or (at your option) any later version,

or

-  the "Artistic License" which comes with this Kit.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See either the
GNU General Public License or the Artistic License for more details.

Versions
--------
Operating System: $^O
Perl            : $]
Tk              : $Tk::VERSION
Data::Dumper    : $Data::Dumper::VERSION
$threadString
EOSTRING

    $self->do_alert(msg => $msg, title => "About ptkdb");
}

#
# return 1 if succesfully set,
# return 0 if otherwise
#
sub SetBreakPoint {
    my ($self, $isTemp) = @_;
    my $lineno = $self->get_lineno();
    my $expr   = $self->clear_entry_text();

    if (!&DB::is_line_breakable($self->{current_file}, $lineno + $self->{'line_offset'})) {
        $self->do_alert(msg => "line $lineno in $self->{current_file} is not breakable");
        return 0;
    }
    if (!$isTemp) {
        $self->insertBreakpoint($self->{current_file}, $lineno, 1, $expr);
        return 1;
    } else {
        $self->insertTempBreakpoint($self->{current_file}, $lineno);
        return 1;
    }
    return 0;
}

sub UnsetBreakPoint {
    my ($self) = @_;
    my $lineno = $self->get_lineno();
    $self->removeBreakpoint($self->{current_file}, $lineno);
}

sub balloon_post {
    my $self = shift;
    my $txt  = $self->{'text'};
    # don't post for an empty string
    return 0 if ($self->{'expr_ballon_msg'} eq q()) || ($self->{'balloon_expr'} eq q());
    return $self->{'balloon_coord'};
}

sub balloon_motion {
    my $self = shift;
    my ($txt, $x, $y) = @_;

    return 0 unless defined $txt && defined $x         && defined $y;
    return 0 unless ref $txt     && $txt->can('rootx') && $txt->can('rooty');

    my ($offset_x, $offset_y) = ($x + 4, $y + 4);
    my $txt2 = $self->{'text'};
    my $data;

    $self->{'balloon_coord'} = "$offset_x,$offset_y";

    $x -= $txt->rootx;
    $y -= $txt->rooty;

    #
    # Post an event that will cause us to put up a popup
    #
    # check to see if 'sel' tag exists (return undef value)
    if ($txt2->tagRanges('sel')) {
        # get the text between the 'first' and 'last' point of the sel (selection) tag
        $data = $txt2->get("sel.first", "sel.last");
    } else {
        $data = $self->retrieve_text_expr($x, $y);
    }

    if (!$data) {
        $self->{'balloon_expr'} = q();
        return 0;
    }

    return 0 if ($data eq $self->{'balloon_expr'});    # nevermind if it's the same expression

    $self->{'event'}        = 'balloon_eval';
    $self->{'balloon_expr'} = $data;

    # balloon will be canceled and a new one put up(maybe)
    return 1;
}

sub retrieve_text_expr {
    ## TODO - 2014-03-10 - MAKE THIS WORK WITH COMPLEX VARS
    my ($self, $x, $y) = @_;
    my $txt = $self->{'text'};

    my $coord = "\@$x,$y";

    my ($idx, $col, $data, $offset);

    ($col, $idx) = $self->line_number_from_coord($txt, $coord);

    $offset = $self->{'linenumber_length'} + 1;    # line number text + 1 space

    return if $col < $offset;                      # no posting

    $col -= $offset;

    $data = DB::get_code_line($self->{current_file}, $idx);
    return if (!defined $data || $data eq '0');    # no executable text, no real variable(?)

    # if we're sitting over white space, leave
    my $len = length $data;
    return unless $data && $col && $len > 0;

    return if substr($data, $col, 1) =~ /\s/;

    # walk backwards till we find some whitespace
    $col = $len if $len < $col;
    while (--$col >= 0) {
        last if substr($data, $col, 1) =~ /[\s\$\@\%]/;
    }

    substr($data, $col) =~ /^([\$\@\%][a-zA-Z0-9_]+)/;
    return $1;
}

#
# after DB::eval gets us a result
#
sub code_motion_eval {
    my ($self, @result) = @_;
    my $str;

    if (exists $self->{'balloon_dumper'}) {
        $str
            = $self->{'balloon_dumper'}->Reset()
            ->Values([$#result == 0 ? @result : \@result])
            ->$dumpFunc();
        chomp($str);
    } else {
        $str = "@result";
    }

    # Cut the string down to 1024 characters to keep from overloading the
    # balloon window.
    $self->{'expr_ballon_msg'} = "$self->{'balloon_expr'} = " . substr $str, 0, 1024;
}

# Subroutine called when we enter DB::DB()
# In other words when the target script 'stops'
# in the Debugger
sub EnterActions {
    my ($self) = @_;
    # Don't know why it's commented out.
    #  $self->{'main_window'}->Unbusy() ;
}

# Subroutine called when we return from DB::DB(); when the target script
# resumes.
sub LeaveActions {
    my ($self) = @_;
    # Don't know why it's commented out.
    # $self->{'main_window'}->Busy() ;
}

#
# Save the ptkdb state file and restart the debugger
#
sub DoRestart {
    my $self = shift;
    my $fdir = $ENV{TMP} || $ENV{TMPDIR} || $ENV{TMP_DIR} || $ENV{TEMP} || $ENV{HOME};
    $fdir = q(.) unless $fdir;

    my $fname = File::Spec->catfile(
        $fdir,
        "ptkdb_restart_state.$$." . strftime('%Y-%m-%dT%H-%M-%S', localtime)
    );
    $self->{state_manager}->save_state_file($fname);

    # go back to where we were when we started
    chdir($self->{restart_dir});

    # original env. we do this assignment after the cdw in case the
    # cwd modifies %ENV.
    %ENV = %{ $self->{restart_ENV} };

    # This setting will be seen by the new process after exec'ing.
    $ENV{DB_RESTART_STATE_FILE} = $fname;

    # Go..
    exec @{ $self->{restart_cmd} };
}

# Enables/Disables the feature where we stop if we've encountered a perl
# warning such as: "Use of uninitialized value at undef_warn.pl line N"
sub stop_on_warning_cb {
    my $self = shift;
    $self->{warn_sig_save}->() if $self->{warn_sig_save};    # call any previously registered warning
    $self->do_alert(msg => @_);
    $DB::single = 1;                                         # forces debugger to stop next time
}

sub set_stop_on_warning {
    my $self = shift;
    if ($self->{stop_on_warning}) {

        return if $self->{warn_sig_save} == \&$self->stop_on_warning_cb;    # prevents recursion

        $self->{warn_sig_save} = $SIG{'__WARN__'} if $SIG{'__WARN__'};
        $SIG{'__WARN__'} = \&$self->stop_on_warning_cb;
    } else {
        #
        # Restore any previous warning signal
        #
        $SIG{'__WARN__'} = $self->{warn_sig_save};
    }
}

# Avoid circular use issues while refactoring.
require Devel::ptkdb::DBHook;

1;

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

If you place the cursor over a variable (i.e. $myVar, @myVar, or %myVar) and
pause for a second the debugger will evaluate the current value of the variable
and pop a balloon up with the evaluated result. If there is an active
selection, the text of that selection will be evaluated.

=back

=head1 Notebook Pane

=over 2

=item Exprs

 This is a list of expressions that are evaluated each time the
 debugger stops. The results of the expresssion are presented
 heirarchically for expression that result in hashes or lists.  Double
 clicking on such an expression will cause it to collapse; double
 clicking again will cause the expression to expand. Expressions are
 entered through B<Enter Expr> entry, or by Ctrl-E when text is
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

stopOnWarning();

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

Sets the fixed font used for code, expressions, and filenames. Defaults to C<Courier 10>.

=item PTKDB_GUI_FONT

Sets the non-fixed font used for GUI elements such as buttons, menus, and labels. Defaults to the normal Tk widget font.

=item PTKDB_CODE_SIDE

Sets which side the code pane is packed onto.  Defaults to 'left'.
Can be set to 'left', 'right', 'top', 'bottom'.

Overrides the Xresource ptkdb*codeside: I<side>.

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

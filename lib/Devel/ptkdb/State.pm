package Devel::ptkdb::State;

# Functions that save and load the information saved in .ptkdb files.

use strict;
use warnings;
use Cwd qw(realpath);
use Data::Dumper;

# Object static data
my %S = (state_api_version => '2.0.0');

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{debugger}        = $args{debugger};
    $self->{state_file_name} = $self->default_state_file_name();
    DBG: 0
        && Devel::ptkdb::debug_say(
        msg => "State new, state file name is " . $self->{state_file_name} || '');
    return $self;
}

sub default_state_file_name {
    my ($self) = @_;

    my $script = Cwd::realpath($0) || $0;
    $script =~ s/\.(?:pl|pm|t)\z//;
    $script .= ".ptkdb";
    DBG: 0 && Devel::ptkdb::debug_say(msg => "in default_state_file_name, returning '$script'");
    return $script;
}

sub state_file_name {
    my ($self, $name) = @_;
    $self->{state_file_name} = $name if @_ > 1 && defined $name && length $name;
    return $self->{state_file_name};
}

sub current_state {
    my ($self) = @_;
    my $debugger = $self->{debugger};

    my $eval_saved_text
        = exists $debugger->{eval_window}
        ? $debugger->{eval_text}->get('0.0', 'end')
        : $debugger->{eval_saved_text};

    return {
        version           => $S{state_api_version},
        files             => DB::breakpoint_state(),
        expr_list         => $debugger->{expr_list},
        eval_saved_text   => $eval_saved_text,
        main_win_geometry => $debugger->{main_window} ? $debugger->{main_window}->geometry : undef,
    };
}

sub apply_state {
    my ($self, $state) = @_;
    return unless $state;

    my $debugger = $self->{debugger};

    DBG: Devel::ptkdb::debug_dump(
        msg    => 'state arg',
        action => 'warntrace',
        dump   => [
            {   name => 'state',
                ref  => $state
            }
        ]
    );
    DB::restore_breakpoint_state($state->{files});

    my $save_cur_file = $debugger->{current_file};

    $debugger->{current_file}    = "";
    $debugger->{expr_list}       = $state->{expr_list} if exists $state->{expr_list};
    $debugger->{eval_saved_text} = $state->{eval_saved_text};

    $debugger->set_file($save_cur_file, $debugger->{current_line});

    if ($state->{main_win_geometry} && $debugger->{main_window}) {
        $debugger->{main_window}->geometry($state->{main_win_geometry});
    }

    $debugger->{event} = 'update';
}

sub write_state_file {
    my ($self, $state_file_name, $state) = @_;

    require Data::Dumper;

    open my $fh, '>', $state_file_name
        or die "Could not open state file $state_file_name: $!";

    my $d = Data::Dumper->new([$state], ['ptkdb_state']);
    $d->Purity(1);

    print {$fh} $d->can('Dumpxs') ? $d->Dumpxs : $d->Dump;
    print {$fh} "\n\$ptkdb_state;\n";

    close $fh
        or die "Could not close state file $state_file_name: $!";
}

sub read_state_file {
    my ($self, $state_file_name) = @_;

    my $state = do $state_file_name;
    if (   not ref($state)
        or ref($state) ne 'HASH'
        or not exists $state->{version}
        or $state->{version} ne $S{state_api_version}) {
        warn
            "State file $state_file_name format does not match the current format. Not loading, Please re-establish your breakpoints, variable watches, etc. and save a new version.\n";
        return {};
    }

    if ($@) {
        die "Could not parse state file $state_file_name: $@";
    }

    if (!defined $state) {
        die "Could not read state file $state_file_name: $!";
    }

    return $state;
}

sub save_state_file {
    my ($self, $state_file_name) = @_;

    $state_file_name ||= $self->state_file_name();
    $self->state_file_name($state_file_name);

    my $state = $self->current_state();
    $self->write_state_file($state_file_name, $state);

    return 1;
}

sub restore_state_file {
    my ($self, $state_file_name) = @_;

    # Set it if not set. Save it either way.
    $state_file_name ||= $self->state_file_name();
    $self->state_file_name($state_file_name);

    return 0 unless -e $state_file_name && -r $state_file_name;

    my $state = $self->read_state_file($state_file_name);
    $self->apply_state($state);

    return 1;
}

sub simplePromptBox {
    my ($self, $title, $defaultText, $okaySub, $cancelSub) = @_;
    my ($top, $entry, $okayBtn);

    my $debugger = $self->{debugger};

    $top = $debugger->{main_window}->Toplevel(-title => $title, -overanchor => 'cursor');

    $Devel::ptkdb::promptString = $defaultText;

    $entry = $top->Entry('-textvariable' => \$Devel::ptkdb::promptString)
        ->pack(-side => 'top', -fill => 'both', -expand => 1);

    $okayBtn = $top->Button(
        -text => "Okay",
        @Devel::ptkdb::button_font, -command => sub { &$okaySub(); $top->destroy; }
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    $top->Button(
        -text    => "Cancel",
        -command => sub { &$cancelSub() if $cancelSub; $top->destroy() },
        @Devel::ptkdb::button_font,
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    $entry->icursor('end');

    $entry->selectionRange(0, 'end') if $entry->can('selectionRange');    # some win32 Tk installations can't do this

    $entry->focus();

    return $top;

}

sub save_state_callback {
    my ($self, $name_in) = @_;

    my $debugger = $self->{debugger};

    my $state_file_name = $name_in || $self->state_file_name();

    my $save_sub = sub {
        my $chosen;
        ## TODO: Get the complete name from the file dialog
        eval { $self->save_state_file($chosen) };
        $debugger->DoAlert($@) if $@;
    };

    my $cancel_sub = sub {
        ## TO DO
        delete $self->{save_box};
    };

    $self->{save_box} = $self->simplePromptBox(
        "Save Config?",
        $state_file_name,
        $save_sub,
        $cancel_sub,
    );
}

sub restore_state_callback {
    my ($self, $name_in) = @_;

    my $debugger = $self->{debugger};

    my $state_file_name = $name_in || $self->state_file_name();

    my $restore_sub = sub {
        my $chosen;
        ## TODO: Get the complete name from the file dialog
        eval { $self->restore_state_file($chosen) };
        $debugger->DoAlert($@) if $@;
    };

    my $cancel_sub = sub {
        ## TO DO
        delete $self->{save_box};
    };

    $self->simplePromptBox(
        "Restore Config?",
        $state_file_name,
        $restore_sub,
        $cancel_sub
    );
}

1;

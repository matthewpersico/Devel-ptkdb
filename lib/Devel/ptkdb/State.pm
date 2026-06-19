package Devel::ptkdb::State;

# Functions that save and load the information saved in .ptkdb files.

use strict;
use warnings;
use Cwd qw(getcwd realpath);
use Data::Dumper;
use File::Basename qw(dirname basename);
use File::Spec;

# Object static data
my %S = (state_api_version => '2.0.0');

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{debugger}        = $args{debugger};
    $self->{state_file_name} = $self->default_state_file_name();
    return $self;
}

sub default_state_file_name {
    my ($self) = @_;

    my $script = Cwd::realpath($0) || $0;
    $script =~ s/\.(?:pl|pm|t)\z//;
    $script .= ".ptkdb";

    if (!-e $script) {
        if (!-w dirname($script)) {
            my $cwd = getcwd();
            $self->{debugger}->DoAlert(
                "'$script' is not writable. Assuming you are debugging a file you do not own. Defaulting to current directory '$cwd'."
            );
            $script = File::Spec->catfile($cwd, basename($script));
        }
    }
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

    open my $fh, '>', $state_file_name
        or die "Could not open state file $state_file_name: $!";

    my $d = Data::Dumper->new([$state], ['ptkdb_state']);
    $d->Purity(1);

    print $fh "## no critic (TestingAndDebugging::RequireUseStrict)\n";
    print $fh $d->can('Dumpxs') ? $d->Dumpxs : $d->Dump;
    print $fh "\nreturn \$ptkdb_state;  # prevents 'only used once' messages\n";

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
        $self->{debugger}->DoAlert(
            "State file $state_file_name format does not match the current format. Not loading, Please re-establish your breakpoints, variable watches, etc. and save a new version."
        );
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

sub choose_state_file {
    my ($self, %args) = @_;

    my $debugger        = $self->{debugger};
    my $main_window     = $debugger->{main_window};
    my $state_file_name = $args{initial} || $self->state_file_name();
    my $initial_dir     = dirname($state_file_name);
    my $initial_file    = basename($state_file_name);

    my %opts = (
        -title            => $args{title} || 'Select ptkdb state file',
        -initialdir       => $initial_dir,
        -initialfile      => $initial_file,
        -defaultextension => '.ptkdb',
        -filetypes        => [
            ['ptkdb state files', ['.ptkdb']],
            ['All files',         ['*']],
        ],
        -force => 1
    );

    my $chosen;
    if (($args{mode} || '') eq 'save') {
        $chosen = $main_window->getSaveFile(%opts);
    } else {
        $chosen = $main_window->getOpenFile(%opts);
    }

    return unless defined $chosen && length $chosen;

    $self->state_file_name($chosen);
    return $chosen;
}

sub save_state_callback {
    my ($self, $name_in) = @_;

    my $debugger = $self->{debugger};

    my $chosen = $self->choose_state_file(
        mode    => 'save',
        title   => 'Save ptkdb state',
        initial => $name_in || $self->state_file_name(),
    );

    return unless defined $chosen;

    eval { $self->save_state_file($chosen) };
    $debugger->DoAlert($@) if $@;
}

sub restore_state_callback {
    my ($self, $name_in) = @_;

    my $debugger = $self->{debugger};

    my $chosen = $self->choose_state_file(
        mode    => 'open',
        title   => 'Restore ptkdb state',
        initial => $name_in || $self->state_file_name(),
    );

    return unless defined $chosen;

    eval { $self->restore_state_file($chosen) };
    $debugger->DoAlert($@) if $@;
}

1;

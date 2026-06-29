package Devel::ptkdb::State;

# Functions that save and load the information saved in .ptkdb files.

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Core and CPAN modules
use Cwd qw(getcwd realpath);
use Data::Dumper;
use File::Basename qw(dirname basename);
use File::Spec;

# ===========================================================================
# Project modules
# None

# ===========================================================================
# Shareable package data
# None

# ===========================================================================
# Object static data
my %S = (state_api_version => '2.0.0');

# ===========================================================================
# Object static methods
sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{'ptkdb_obj'}       = $args{ptkdb_obj};
    $self->{'state_file_name'} = $self->default_state_file_name();
    return $self;
}

# ===========================================================================
# Object instance methods
sub default_state_file_name {
    my ($self) = @_;

    my $script = Cwd::realpath($0) || $0;
    $script =~ s/\.(?:pl|pm|t)\z//;
    $script .= ".ptkdb";

    if (!-e $script) {
        if (!-w dirname($script)) {
            my $cwd = getcwd();
            $self->{'ptkdb_obj'}->do_alert(msg =>
                    "'$script' is not writable. Assuming you are debugging a file you do not own. Defaulting to current directory '$cwd'."
            );
            $script = File::Spec->catfile($cwd, basename($script));
        }
    }
    return $script;
}

sub state_file_name {
    my ($self, $name) = @_;
    $self->{'state_file_name'} = $name if @_ > 1 && defined $name && length $name;
    return $self->{'state_file_name'};
}

sub current_state {
    my ($self) = @_;
    my $ptkdb_obj = $self->{'ptkdb_obj'};

    my $eval_saved_text
        = exists $ptkdb_obj->{'eval_window'}
        ? $ptkdb_obj->{'eval_text'}->get('0.0', 'end')
        : $ptkdb_obj->{'eval_saved_text'};

    my $code_pane_size;
    if (my $frame = $ptkdb_obj->{'code_frame'}) {
        my $side = $ptkdb_obj->{'code_side'} // 'left';
        $code_pane_size
            = ($side eq 'left' || $side eq 'right')
            ? $frame->width
            : $frame->height;
    }

    return {
        version           => $S{state_api_version},
        files             => DB::breakpoint_state(),
        expr_list         => $ptkdb_obj->{'expr_list'},
        eval_saved_text   => $eval_saved_text,
        main_win_geometry => $ptkdb_obj->{'main_window'}
        ? $ptkdb_obj->{'main_window'}->geometry
        : undef,
        code_pane_size => $code_pane_size,
    };
}

sub apply_state {
    my ($self, $state) = @_;
    return unless $state;

    my $ptkdb_obj = $self->{'ptkdb_obj'};

    DB::restore_breakpoint_state($state->{'files'});

    my $save_cur_file = $ptkdb_obj->{'current_file'};

    $ptkdb_obj->{'current_file'}    = "";
    $ptkdb_obj->{'expr_list'}       = $state->{'expr_list'} if exists $state->{'expr_list'};
    $ptkdb_obj->{'eval_saved_text'} = $state->{'eval_saved_text'};

    $ptkdb_obj->set_file($save_cur_file, $ptkdb_obj->{'current_line'});

    if ($state->{'main_win_geometry'} && $ptkdb_obj->{'main_window'}) {
        $ptkdb_obj->{'main_window'}->geometry($state->{'main_win_geometry'});
    }

    if ($state->{'code_pane_size'} && $ptkdb_obj->{'code_frame'}) {
        my $frame = $ptkdb_obj->{'code_frame'};
        my $size  = $state->{'code_pane_size'};
        my $side  = $ptkdb_obj->{'code_side'} // 'left';
        my $dim   = ($side eq 'left' || $side eq 'right') ? '-width' : '-height';
        if ($frame->ismapped) {
            # Window already up (e.g. manual reload): afterIdle is enough.
            $ptkdb_obj->{'main_window'}->afterIdle(sub { $frame->configure($dim => $size) });
        } else {
            # Startup: the Adjuster's Mapped callback hasn't fired yet. Store
            # the desired size for EnterActions() to apply after forcing the
            # window to map and settle via update().
            $ptkdb_obj->{'pending_code_pane_size'} = { dim => $dim, size => $size };
        }
    }

    $ptkdb_obj->{'event'} = 'update';
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
        or not exists $state->{'version'}
        or $state->{'version'} ne $S{state_api_version}) {
        $self->{'ptkdb_obj'}->do_alert(msg =>
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

    my $ptkdb_obj       = $self->{'ptkdb_obj'};
    my $main_window     = $ptkdb_obj->{'main_window'};
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

    my $ptkdb_obj = $self->{'ptkdb_obj'};

    my $chosen = $self->choose_state_file(
        mode    => 'save',
        title   => 'Save ptkdb state',
        initial => $name_in || $self->state_file_name(),
    );

    return unless defined $chosen;

    eval { $self->save_state_file($chosen) };
    $ptkdb_obj->do_alert(msg => $@) if $@;
}

sub restore_state_callback {
    my ($self, $name_in) = @_;

    my $ptkdb_obj = $self->{'ptkdb_obj'};

    my $chosen = $self->choose_state_file(
        mode    => 'open',
        title   => 'Restore ptkdb state',
        initial => $name_in || $self->state_file_name(),
    );

    return unless defined $chosen;

    eval { $self->restore_state_file($chosen) };
    $ptkdb_obj->do_alert(msg => $@) if $@;
}

1;

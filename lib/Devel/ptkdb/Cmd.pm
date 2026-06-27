package Devel::ptkdb::Cmd;

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Core and CPAN modules
# None

# ===========================================================================
# Project modules
# None

# ===========================================================================
# Shareable package data
# None

# ===========================================================================
# Package data
my @execute_msg = (
    "Currently supported commands are:",
    "h   - pop up this dialog",
    "n   - step over line",
    "s   - step into line",
    "r   - return",
    "c   - continue",
    "l # - goto line # in current code",
    "l   - page down in current code",
    "q   - quit"
);

# ===========================================================================
# Object static methods
sub new {
    my ($class, %args) = @_;

    die "ptkdb_obj is required" unless $args{ptkdb_obj};

    return bless {
        ptkdb_obj => $args{ptkdb_obj},
    }, $class;
}

# ===========================================================================
# Object instance methods
sub execute {
    my ($self, $command) = @_;

    $command //= '';
    $command =~ s/^\s+|\s+$//g;

    my $ptkdb_obj = $self->{ptkdb_obj};

    my @last;
    push @last, $ptkdb_obj->{command_line_last} if $ptkdb_obj->{command_line_last};
    push @last, $command;
    my $retval = '<no command>';

    # Try to keep these in most to least likely to be used order.
    if ($command eq '') {
        if ($ptkdb_obj->{command_line_last}) {
            $command = $ptkdb_obj->{command_line_last};
        } else {
            $ptkdb_obj->do_alert(
                title => 'Debugger Command Line Error',
                msg   => ['No command entered.', @execute_msg]
            );
            return;
        }
    }

    if ($command eq 'n') {
        $retval = $ptkdb_obj->{shared_callbacks}->{stepOverSub}->();
    } elsif ($command eq 's') {
        $retval = $ptkdb_obj->{shared_callbacks}->{stepInSub}->();
    } elsif ($command eq 'c') {
        $retval = $ptkdb_obj->{shared_callbacks}->{runSub}->();
    } elsif ($command eq 'r') {
        $retval = $ptkdb_obj->{shared_callbacks}->{returnSub}->();
    } elsif ($command eq 'q') {
        $retval = $ptkdb_obj->{shared_callbacks}->{quitSub}->();
    } elsif ($command eq 'h') {
        $ptkdb_obj->do_alert(
            title => 'Debugger Command Line Help',
            msg   => \@execute_msg
        );
        return;
    } elsif ($command =~ /^l\s+(\d+)$/) {
        $retval = $ptkdb_obj->goto_code_line($1);
    } elsif ($command eq 'l') {
        $retval = $ptkdb_obj->page_code_window();
    }

    if ($retval && $retval eq '<no command>') {
        $ptkdb_obj->do_alert(
            title => 'Ptkdb_Obj Command Line Error',
            msg   => ["Unknown ptkdb_obj command: $command", @execute_msg]
        );
        return;
    } else {
        $ptkdb_obj->{command_line_last} = $command;
        return $retval;
    }
}

1;

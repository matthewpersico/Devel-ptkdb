package Devel::ptkdb::Cmd;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    die "window is required" unless $args{window};

    return bless {
        window => $args{window},
    }, $class;
}

sub execute {
    my ($self, $command) = @_;

    $command //= '';
    $command =~ s/^\s+|\s+$//g;

    my $window = $self->{window};

    my @last;
    push @last, $window->{command_line_last} if $window->{command_line_last};
    push @last, $command;
    my $retval = '<no command>';
    ## Try to keep these in most to least likely to be used order.
    if ($command eq '') {
        if ($window->{command_line_last}) {
            $command = $window->{command_line_last};
        } else {
            $window->do_alert(
                -title => 'Debugger Command Line Error',
                -msg   => [
                    "No command entered. Currently supported commands are:",
                    "n   - step over line",
                    "s   - step into line",
                    "r   - return",
                    "c   - continue",
                    "l # - goto line # in current code",
                    "q   - quit"
                ]
            );
            return;
        }
    }

    if ($command eq 'n') {
        $retval = $window->{shared_callbacks}->{stepOverSub}->();
    } elsif ($command eq 's') {
        $retval = $window->{shared_callbacks}->{stepInSub}->();
    } elsif ($command eq 'c') {
        $retval = $window->{shared_callbacks}->{runSub}->();
    } elsif ($command eq 'r') {
        $retval = $window->{shared_callbacks}->{returnSub}->();
    } elsif ($command eq 'q') {
        $retval = $window->{shared_callbacks}->{quitSub}->();
    } elsif ($command =~ /^l\s+(\d+)$/) {
        $retval = $window->goto_code_line($1);
    }

    if ($retval eq '<no command>') {
        $window->do_alert(
            -title => 'Debugger Command Line Error',
            -msg   => "Unknown debugger command: $command"
        );
        return;
    } else {
        $window->{command_line_last} = $command;
        return;
    }
}

1;

package Devel::ptkdb::Playlist;
#
# Tk::Playlist class - provides winamp-style "playlist" editing capibilities.
#
# By Tyler "Crackerjack" MacDonald <crackerjack@crackerjack.net>
# July 23rd, 2000.
# Package-ified November 25, 2004,
#
# This module is freeware; You may redistribute it under the same terms as
# perl itself.
#

# We have copied our own version instead of using an installed copy because we
# have made some changes specfic to the debugger.

# ===========================================================================
# Pragmas
use strict;
use vars qw($VERSION @ISA);

# ===========================================================================
# Core and CPAN modules
use Tk;
use Tk::Derived;
use Tk::HList;

$VERSION = '0.02';
@ISA     = qw(Tk::Derived Tk::HList);

Construct Tk::Widget 'Playlist';

sub Tk::Widget::ScrolledPlaylist { shift->Scrolled('Playlist' => @_); }

return 1;

sub ClassInit {
    my ($class, $mw) = @_;

    $mw->eventAdd('<<Toggle>>'        => '<Control-ButtonPress-1>');
    $mw->eventAdd('<<RangeSelect>>'   => '<Shift-ButtonPress-1>');
    $mw->eventAdd('<<MoveEntries>>'   => '<B1-Motion>');
    $mw->eventAdd('<<InverseSelect>>' => '<Control-ButtonPress-2>');
    $mw->eventAdd('<<SingleSelect>>'  => '<ButtonPress-1>');
    $mw->eventAdd('<<EndMovement>>'   => '<ButtonRelease-1>');
    $mw->eventAdd('<<Delete>>'        => '<Key-Delete>');

    # Hlist
    $mw->eventAdd('<<DoubleSelect>>' => '<Double-ButtonPress-1>');

    $mw->bind($class, '<<Toggle>>',       ['Toggle']);
    $mw->bind($class, '<<SingleSelect>>', ['SingleSelect']);
    $mw->bind($class, '<<RangeSelect>>',  ['RangeSelect']);
    $mw->bind($class, '<<MoveEntries>>',  ['MoveEntries']);
    $mw->bind($class, '<<EndMovement>>',  ['EndMovement']);
    $mw->bind($class, '<<Delete>>',       ['Delete']);

    # Hlist
    $mw->bind($class, '<<DoubleSelect>>', ['DoubleSelect']);

    #>>>>>>>>> $class->SUPER::ClassInit($mw);
}

# Hlist
sub DoubleSelect {
    my $w  = shift;
    my $Ev = $w->XEvent;

    delete $w->{'shiftanchor'};

    my $ent = $w->GetNearest($Ev->y, 1);

    return unless (defined($ent) and length($ent));

    $w->anchorSet($ent)
        unless (defined $w->info('anchor'));

    $w->selectionSet($ent);

    $w->Callback(-command => $ent);
}

sub Populate {
    my ($cw, $args) = @_;
    my $f;

    $cw->ConfigSpecs('-style'           => ['PASSIVE', undef, undef, undef]);
    $cw->ConfigSpecs('-readonly'        => ['METHOD',  undef, undef, undef]);
    $cw->ConfigSpecs('-callback_change' => ['METHOD',  undef, undef, undef]);

    $cw->SUPER::Populate($args);
}

sub Delete {
    my ($cw) = @_;

    return if ($cw->{'readonly'});

    my @is = $cw->infoSelection();
    grep { $cw->deleteEntry($_) } @is;

    if ($cw->{'callback_change'}) {
        my ($cmd, @arg);
        if (ref($cw->{callback_change}) eq 'ARRAY') {
            ($cmd, @arg) = @{ $cw->{callback_change} };
        } elsif (ref($cw->{callback_change}) eq 'CODE') {
            ($cmd, @arg) = ($cw->{callback_change});
        }

        if ($cmd) {
            foreach my $i (@is) {
                $cmd->($cw, 'delete', $i, @arg);
            }
        }
    }
}

sub InverseSelect {
    my ($w) = @_;
    my (%ic, @is);
    grep { $ic{$_}++ } $w->infoSelection();
    @is = grep { !$ic{$_} } $w->infoChildren();
    $w->selectionClear();
    grep($w->selectionSet($_), @is);
}

sub evFindClick {
    my ($w, $Ev) = @_;
    $w->GetNearest($Ev->y, 1);
}

sub findClick {
    $_[0]->evFindClick($_[0]->XEvent);
}

sub EndMovement {
    my ($cw, $args) = @_;
    if ($cw->{moving}) {
        delete($cw->{moving});
        if ($cw->{callback_change}) {
            my ($cmd, @arg);
            if (ref($cw->{callback_change}) eq 'ARRAY') {
                ($cmd, @arg) = @{ $cw->{callback_change} };
            } elsif (ref($cw->{callback_change}) eq 'CODE') {
                ($cmd, @arg) = ($cw->{'callback_change'});
            }
            if ($cmd) {
                $cmd->($cw, 'done_moving', @arg);
            }
        }
    }
}

sub MoveEntries {
    my ($cw, $args) = @_;
    my ($Ev, $yy, $dir, $ent);

    return if ($cw->{readonly});

    $Ev  = $cw->XEvent;
    $yy  = $Ev->y;
    $ent = $cw->evFindClick($Ev);

    if (!$cw->{moving}) {
        $cw->{moving}  = $yy;
        $cw->{old_ent} = $ent;
    } else {
        if ($cw->{moving} > $yy && $cw->{moving} - 10 > $yy) {
            $dir = -1;
        } elsif ($cw->{moving} < $yy && $cw->{moving} + 10 < $yy) {
            $dir = 1;
        }
        if ($ent && $cw->{old_ent} && $ent eq $cw->{old_ent}) {
            $dir = 0;
        }

        $cw->{old_ent} = $ent;

        if ($Ev->y + 10 >= $cw->height) {
            $dir = 1;
        } elsif ($Ev->y - 10 <= 0) {
            $dir = -1;
        }

        if ($dir) {
            my (@ic, %ic, @is, $icc, @iss);
            @ic = $cw->infoChildren();
            grep { $ic{ $ic[$_] } = $_ } $[ .. $#ic;
            @is = $cw->infoSelection();
            if ($dir == 1) {
                @iss = reverse(@is);
            } else {
                @iss = @is;
            }

            foreach my $ii (@iss) {
                my $pos;
                $icc = [tk_to_cfg_args($cw->entryconfigure($ii))];
                if (!exists $ic{$ii}) {
                    if ($ent) {
                        $pos = $ic{$ent} + $dir;
                    } elsif ($Ev->y < 10) {
                        $pos = 0;
                    } else {
                        $pos = $#ic;
                    }
                } else {
                    $pos = $ic{$ii} + $dir;
                }
                if ($pos < 0) {
                    $pos = 0;
                } elsif ($pos > $#ic) {
                    $pos = $#ic;
                }

                if ($pos != $ic{$ii}) {
                    $cw->selectionClear($ii);
                    $cw->deleteEntry($ii);
                    $cw->add($ii, @$icc, -at => $pos);
                    $cw->selectionSet($ii);
                    $cw->anchorSet($ii);

                    if ($cw->{callback_change}) {
                        my ($cmd, @arg);
                        if (ref($cw->{callback_change}) eq 'ARRAY') {
                            ($cmd, @arg) = @{ $cw->{callback_change} };
                        } elsif (ref($cw->{callback_change}) eq 'CODE') {
                            ($cmd, @arg) = ($cw->{callback_change});
                        }

                        if ($cmd) {
                            &{$cmd}($cw, 'move', $ii, $pos, @arg);
                        }
                    }
                }

                if ($pos != 0 && $pos != $#ic) {
                    $cw->{moving} = $Ev->y;
                }
            }

            if ($dir == -1 && @is) {
                $cw->see($is[0]);
            } elsif ($dir == 1 && @is) {
                $cw->see($is[$#is]);
            }
        }
    }
}

sub tk_to_cfg_args {
    my (@tk) = @_;
    my (@rv, $i);
    while ($i = shift(@tk)) {
        push(@rv, $i->[0]);
        push(@rv, $i->[$#$i]);
    }
    @rv;
}

sub RangeSelect {
    my $w = shift;
    my $ent;

    $w->focus() if ($w->cget('-takefocus'));
    $w->selectionClear();

    if ($ent = $w->findClick) {
        my $nent;
        unless ($nent = $w->infoAnchor()) {
            $nent = $ent;
        }

        if ($w->selectionIncludes($ent)) {
            $w->selectionClear($ent, $nent);
        } else {
            $w->selectionSet($ent, $nent);
        }
        $w->anchorSet($ent);
    }
}

sub SingleSelect {
    my $w = shift;
    my $ent;

    $w->focus() if ($w->cget('-takefocus'));
    $w->selectionClear();

    if ($ent = $w->findClick) {
        $w->selectionSet($ent, $ent);
        $w->anchorSet($ent);
    } else {
        $w->anchorClear();
    }
}

sub Toggle {
    my $w = shift;
    my $ent;

    $w->focus() if ($w->cget('-takefocus'));

    if ($ent = $w->findClick) {
        if ($w->selectionIncludes($ent)) {
            $w->selectionClear($ent, $ent);
        } else {
            $w->selectionSet($ent, $ent);
        }
        $w->anchorSet($ent);
    } else {
        $w->anchorClear();
    }
}

sub add_entry {
    my ($cw, $eid, $etxt, $st) = @_;
    $cw->add($eid, -text => $etxt, -style => $st || $cw->cget('-style'));
}

sub readonly {
    my ($cw, $val) = @_;
    my $rv = $cw->{readonly};
    if (defined($val)) {
        $cw->{readonly} = $val;
    }
    $rv;
}

sub callback_change {
    my ($cw, $val) = @_;
    my $rv = $cw->{callback_change};
    if (defined($val)) {
        $cw->{callback_change} = $val;
    }
    $rv;
}

1;
__END__

=headl NAME

Tk::Playlist - Tk::HList subclass providing playlist-like manipulation

=headl SYNOPSIS

 use Tk::Playlist;

 my $playlist = $widget->Playlist(-readonly => 0);
 splaylist->add("foobar.mp3", -text => "The FooBar Song");
 splaylist->{callback_change}([ \&rewrite_m3u, "filename.m3u" ] );

=headl DESCRIPTION

The Tk::Playlist widget is derived from the standard Tk::HList widget.
See its documentation for more information.

In addition to the standard HList functionality, the Tk::Playlist widget
adds the ability to modify the list directly. Users may drag entries up
and down the list and delete items from the list using the "Delete" key.

=headl WIDGET-SPECIFIC OPTIONS

 over

=item Switch: B<-readonly>

=item Method: B<readonly>

Specifies that the list may not be modified.

=item Switch: B<-callback_change>

=item Method: B<callback_change>

Specifies a Tk callback to be executed whenever the list is changed by
the user. The callback is called once for each item that has changed,
the first parameter is either "move" (to indicate an item has been
moved), "done_moving" (to indicate the user has released the mouse
button and is done dragging entries around), or "delete" (to indicate
an item has been deleted).

When the first parameter is "move" or "delete", the second parameter
is the tag that was assigned to the item (see Tk::HList->add for more
info).

When the first parameter is "move", the third parameter is the new
position of the item on the list, with the top of the list being "0".

=back

=headl BUGS

When a user attempts to drag an entry beyond the top of the list, the
position (third) parameter passed to C<callback_change> is "0". This
could be considered a bug or a feature.

=headl SEE ALSO

L<Tk::HList>, L<Tk::callbacks>

=headl AUTHOR

Tyler MacDonald, E<lt>japh@crackerjack.netE<gt>

=headl COPYRIGHT AND LICENSE

Copyright (C) 2004 by Tyler MacDonald

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.

=cut

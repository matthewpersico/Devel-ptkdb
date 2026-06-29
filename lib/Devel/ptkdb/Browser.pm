package Devel::ptkdb::Browser;

# ===========================================================================
# Pragmas
use strict;
use warnings;

# ===========================================================================
# Core and CPAN modules
use Config;
use File::Spec;

# ===========================================================================
# Project modules
# None

# ===========================================================================
# Shareable package data
# None

# ===========================================================================
# Package data

# ===========================================================================
# Object static methods
sub new {
    my ($class) = @_;
    return bless { browser => find_default_browser() }, $class;
}

sub is_mswindows {
    Devel::ptkdb::is_mswindows();
}

sub find_default_browser {
    if (is_mswindows()) {
        return default_browser_mswindows();
    } else {
        return default_browser_linux();
    }
}

sub default_browser_linux {
    # Try xdg-settings first (most reliable)
    my $default = `xdg-settings get default-web-browser 2>/dev/null`;
    chomp $default if $default;

    if ($default && $default =~ /\.desktop$/) {
        my $exec = extract_exec_from_desktop($default);
        return $exec if $exec;
    }

    # Fallback: check mimeapps.list
    my @mime_files = (
        "$ENV{HOME}/.config/mimeapps.list",
        "$ENV{HOME}/.local/share/applications/mimeapps.list",
    );

    foreach my $file (@mime_files) {
        next unless -f $file;
        open my $fh, '<', $file or next;
        while (<$fh>) {
            if (/^text\/html\s*=\s*(.+)/) {
                my $desktop = (split /;/, $1)[0];
                my $exec    = extract_exec_from_desktop($desktop);
                return $exec if $exec;
            }
        }
        close $fh;
    }

    # Final fallback
    return $ENV{BROWSER} || undef;
}

sub extract_exec_from_desktop {
    my ($desktop) = @_;
    my @paths = (
        "$ENV{HOME}/.local/share/applications/$desktop",
        "/usr/share/applications/$desktop",
    );

    foreach my $path (@paths) {
        next unless -f $path;
        open my $fh, '<', $path or next;
        while (<$fh>) {
            if (/^Exec\s*=\s*(.+)/) {
                my $exec = $1;
                $exec =~ s/\s+%[a-zA-Z]//g;    # remove placeholders
                return $exec;
            }
        }
        close $fh;
    }
    return wantarray ? () : undef;
}

sub default_browser_mswindows {
    require Win32::TieRegistry;
    Win32::TieRegistry->import(':KEY_');

    my $reg = Win32::TieRegistry->new(
        "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\http\\UserChoice",
        { Delimiter => "\\" }
    ) or return wantarray ? () : undef;

    my $prog_id = $reg->{'ProgId'} or return wantarray ? () : undef;

    # Now resolve the command line
    my $cmd_key = "HKEY_CLASSES_ROOT\\$prog_id\\shell\\open\\command";
    my $cmd_reg = Win32::TieRegistry->new($cmd_key, { Delimiter => "\\" });
    return $cmd_reg && $cmd_reg->{'/'} ? $cmd_reg->{'/'} : undef;
}

sub find_installed_browsers {
    my @browsers;

    if (is_mswindows()) {
        push @browsers, installed_browsers_mswindows();
    } else {
        push @browsers, installed_browsers_linux();
    }

    return @browsers;
}

sub installed_browsers_linux {
    my @candidates = qw(
        google-chrome chromium brave-browser firefox
        opera microsoft-edge vivaldi
    );

    my @found;
    foreach my $name (@candidates) {
        my $path = `which $name 2>/dev/null`;
        chomp $path;
        push @found, { name => $name, path => $path } if $path;
    }

    # Also check Flatpak and Snap if desired
    return @found;
}

sub installed_browsers_mswindows {
    my @found;
    require Win32::TieRegistry;
    Win32::TieRegistry->import(':KEY_');

    my @roots = (
        "HKEY_LOCAL_MACHINE\\SOFTWARE\\Clients\\StartMenuInternet",
        "HKEY_CURRENT_USER\\SOFTWARE\\Clients\\StartMenuInternet",
    );

    foreach my $root (@roots) {
        my $reg = Win32::TieRegistry->new($root, { Delimiter => "\\" }) or next;
        foreach my $key ($reg->SubKeyNames) {
            my $name = $key;
            my $cmd  = $reg->{"$key\\shell\\open\\command\\"} || '';
            push @found, { name => $name, path => $cmd } if $cmd;
        }
    }

    return @found;
}

# ===========================================================================
# Object instance methods

sub cmd {
    my $self = shift;
    if (@_) {
        confess("Devel::ptkdb::Browser::cmd() is a read only method");
    }
    return $self->{'browser'};
}

sub open_url {
    my ($self, $url) = @_;

    my $browser_cmd;
    my $default = $self->cmd();

    # Get the browser command
    if (is_mswindows()) {
        # On Windows, use the found default or fall back to 'start'
        if ($default) {
            # The registry value usually needs the URL appended
            $browser_cmd = $default;
            $browser_cmd =~ s/["']?\s*%1["']?\s*$//;    # remove %1 placeholder if present
        } else {
            $browser_cmd = 'start ""';
        }
    } else {
        # On Linux, use the found default or fall back to xdg-open.
        if (qx{which xdg-open 2>/dev/null}) {
            $browser_cmd = 'xdg-open';
        } elsif ($default) {
            $browser_cmd = $default;
        } else {
            $browser_cmd = $ENV{BROWSER} || 'xdg-open';
        }
    }

    # Add in the URL
    my $cmd;
    if (is_mswindows()) {
        if ($browser_cmd =~ /^start/i) {
            $cmd = qq{start "" "$url"};
        } else {
            $cmd = qq{$browser_cmd "$url"};
        }
    } else {
        $cmd = qq{$browser_cmd "$url"};
    }

    # Launch asynchronously (non-blocking)
    if (is_mswindows()) {
        # Windows: use system(1, ...) or start in background
        system(1, $cmd);
    } else {
        # Unix: fork + exec so we don't block
        my $pid = fork();
        if (!defined $pid) {
            warn "open_url: fork failed: $!\n";
            return;
        }
        if ($pid == 0) {
            # Child process
            exec($cmd) or warn "open_url: exec failed: $!\n";
            exit 1;
        }
        # Parent continues immediately
    }
}

1;

#!/usr/bin/perl -w

=head1 NAME

Debconf::DbDriver::Pipe - read/write database from file descriptors

=cut

package Debconf::DbDriver::Pipe;
use strict;
use Debconf::Log qw(:all);
use base 'Debconf::DbDriver::Cache';

=head1 DESCRIPTION

This is a debconf database driver that reads the db from a file descriptor when
it starts, and writes it out to another when it saves it. By default, stdin
and stdout are used.

=head1 FIELDS

=over 4

=item infd

File descriptor number to read from. Defaults to reading from stdin. If
it's set to "none", the db won't bother to try to read in an initial
database.

=item outfd

File descriptor number to write to. Defaults to writing to stdout. If
it's set to "none", the db will be thrown away rather than saved.

Setting both infd and outfd to none gets you a writable temporary db in
memory.

=item format

The Format object to use for reading and writing.

In the config file, just the name of the format to use, such as '822' can
be specified. Default is 822.

=back

=cut

use fields qw(infd outfd format continuous exists);

my $fh;

=head1 METHODS

=head2 init

On initialization, load the entire db into memory and populate the cache.

=cut

sub init {
	my $this=shift;

	$this->{format} = "822" unless exists $this->{format};

	$this->error("No format specified") unless $this->{format};
	eval "use Debconf::Format::$this->{format}";
	if ($@) {
		$this->error("Error setting up format object $this->{format}: $@");
	}
	$this->{format}="Debconf::Format::$this->{format}"->new;
	if (not ref $this->{format}) {
		$this->error("Unable to make format object");
	}

	if (defined $this->{infd}) {
		if ($this->{infd} ne 'none') {
			open ($fh, "<&=$this->{infd}") or
				$this->error("could not open file descriptor #$this->{infd}: $!");
		}
	}
	else {	
		open ($fh, '-');
	}

	$this->SUPER::init(@_);

	debug "db $this->{name}" => "loading database";

	$this->read_pipe;
}

=sub shutdown

Save the entire cache out to the fd. Always writes the cache, even if it's
not dirty, for consistency's sake.

=cut

sub shutdown {
	my $this=shift;

	return if $this->{readonly};

	my $fh;
	if (defined $this->{outfd}) {
		if ($this->{outfd} ne 'none') {
			open ($fh, ">&=$this->{outfd}") or
				$this->error("could not open file descriptor #$this->{outfd}: $!");
		}
	}
	else {
		open ($fh, '>-');
	}
	
	if (defined $fh) {
		$this->{format}->beginfile;
		foreach my $item (sort keys %{$this->{cache}}) {
			next unless defined $this->{cache}->{$item}; # skip deleted
			$this->{format}->write($fh, $this->{cache}->{$item}, $item)
				or $this->error("could not write to pipe: $!");
		}
		$this->{format}->endfile;
		close $fh or $this->error("could not close pipe: $!");
	}

	return 1;
}

=sub load

If continuous=1, we keep pipe open and try to read new
data from it on load().

=cut

sub load {
	my $this=shift;

	return undef if ! $this->{continuous};

	$this->read_pipe;
}


=sub read_pipe

Generic pipe reading routine.

=cut

sub read_pipe {
	my $this=shift;

	# Now read in available data using the Format object.
	if (defined $fh) {
		while (! eof $fh) {
			my ($item, $cache)=$this->{format}->read($fh);
			$this->{cache}->{$item}=$cache;
		}
		close $fh if not $this->{continuous};
	}
}

=head1 AUTHOR

Joey Hess <joeyh@debian.org>

=cut

1

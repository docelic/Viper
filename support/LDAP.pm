#!/usr/bin/perl -w
# This file was preprocessed, do not edit!


package Debconf::DbDriver::LDAP;
use strict;
use Debconf::Log qw(:all);
use Net::LDAP;
use base 'Debconf::DbDriver::Cache';


use fields qw(server port basedn binddn bindpasswd exists keybykey ds accept_attribute reject_attribute priority location);


sub exists {
	my ($this, $item) = (shift, shift);

	if (!exists($this->{cache}->{$item}) and $this->{keybykey}) {
		$this->load($item);
	}

	$this->SUPER::exists($item);
}

sub binddb {
	my $this=shift;

	$this->error("No server specified") unless exists $this->{server};
	$this->error("No Base DN specified") unless exists $this->{basedn};
	
	$this->{binddn} = "" unless exists $this->{binddn};
	$this->{port} = 389 unless exists $this->{port};
	
	debug "db $this->{name}" => "talking to $this->{server}, data under $this->{basedn}";

	$this->{ds} = Net::LDAP->new($this->{server}, port => $this->{port}, version => 3);
	if (! $this->{ds}) {
		$this->error("Unable to connect to LDAP server");
		return; # if not fatal, give up anyway
	}
	
	my $rv = "";
	if (!($this->{binddn} && $this->{bindpasswd})) {
		debug "db $this->{name}" => "binding anonymously; hope that's OK";
		$rv = $this->{ds}->bind;
	} else {
		debug "db $this->{name}" => "binding as $this->{binddn}";
		$rv = $this->{ds}->bind($this->{binddn}, password => $this->{bindpasswd});
	}
	if ($rv->code) {
		$this->error("Bind Failed: ".$rv->error);
	}
	
	return $this->{ds};
}


sub init {
	my $this = shift;

	$this->SUPER::init(@_);

	$this->binddb;
	return unless $this->{ds};

	$this->{exists} = {};
	
	if ($this->{keybykey}) {
		debug "db $this->{name}" => "will get database data key by key";
	}
	else {
		debug "db $this->{name}" => "getting database data";
		my $base = $this->{basedn};
		my $data = $this->{ds}->search(base => $base, sizelimit => 0, timelimit => 0, filter => "(objectclass=debconfDbEntry)");
		if ($data->code) {
			$this->error("Search failed for $base: ".$data->error);
		}
			
		my $records = $data->as_struct();
		debug "db $this->{name}" => "Read ".$data->count()." entries";	
	
		$this->parse_records($records);
	}
}


sub shutdown
{
	my $this = shift;
	
	return if $this->{readonly};
	
	if (grep $this->{dirty}->{$_}, keys %{$this->{cache}}) {
		debug "db $this->{name}" => "saving changes";
	} else {
		debug "db $this->{name}" => "no database changes, not saving";
		return 1;
	}

	$this->write_records();

	$this->SUPER::shutdown(@_);

	$this->{ds}->unbind;
}


sub load {
	my $this = shift;
	return unless $this->{keybykey};
	my $key = shift;

	my $records = $this->get_key($key);
	return unless $records;
		
	debug "db $this->{name}" => "Read entry for $key";

	$this->parse_records($records);
}


sub remove {
	return 1;
}


sub save {
	my $this = shift;

	return 1 unless $this->{keybykey};

	$this->write_records(@_);
}


sub get_key {
	my $this = shift;
	return unless $this->{keybykey};
	my $entry_cn = shift;
	my $base = 'cn=' . $entry_cn . ',' . $this->{basedn};

	my $data = $this->{ds}->search(
		base => $base,
		sizelimit => 0,
		timelimit => 0,
		filter => "(objectclass=debconfDbEntry)");

	if ($data->code) {
		# Failed search is not a fatal error in keybykey mode.
		# It only means the specific entry requested was not found in the
		# LDAP server, which is a regular thing to happen on first install
		# of a package.
		if ( !$this->{keybykey} ) {
			$this->error("Search failed for $base: ".$data->error);
		}
		return;
	}

	return unless $data->entries;
	$data->as_struct();
}


sub parse_records {
	my $this = shift;
	my $records = shift;

	foreach my $dn (keys %{$records}) {
		my $entry = $records->{$dn};
		debug "db $this->{name}" => "Reading data from $dn";
		my %ret = (owners => {},
			fields => {},
			variables => {},
			flags => {},
		);
		my $name = "";

		foreach my $attr (keys %{$entry}) {
			if ($attr eq 'objectclass') {
				next;
			}
			my $values = $entry->{$attr};

			$attr =~ s/([a-z])([A-Z])/$1.'_'.lc($2)/ge;

			debug "db $this->{name}" => "Setting data for $attr";
			foreach my $val (@{$values}) {
				debug "db $this->{name}" => "$attr = $val";
				if ($attr eq 'owners') {
					$ret{owners}->{$val}=1;
				} elsif ($attr eq 'flags') {
					$ret{flags}->{$val}='true';
				} elsif ($attr eq 'cn') {
					$name = $val;
				} elsif ($attr eq 'variables') {
					my ($var, $value)=split(/\s*=\s*/, $val, 2);
					$ret{variables}->{$var}=$value;
				} else {
					$val=~s/\\n/\n/g;
					$ret{fields}->{$attr}=$val;
				}
			}
		}

		$this->{cache}->{$name} = \%ret;
		$this->{exists}->{$name} = 1;
	}
}


sub write_records
{
	my ($this, $key) = (shift, shift);
	
	my @keys = $key ? ($key) : keys %{$this->{cache}};

	foreach my $item (@keys) {
		next unless defined $this->{cache}->{$item};  # skip deleted
		next unless $this->{dirty}->{$item};	# skip unchanged
		(my $entry_cn = $item) =~ s/([,+="<>#;])/\\$1/g;
		my $entry_dn = "cn=$entry_cn,$this->{basedn}";
		debug "db $this->{name}" => "writing out to $entry_dn";
		
		my %data = %{$this->{cache}->{$item}};
		my %modify_data;
		my $add_data = [ 'objectclass' => 'top',
				'objectclass' => 'debconfdbentry',
				'cn' => $item,
				@_
		];

		my @fields = keys %{$data{fields}};
		foreach my $field (@fields) {
			my $ldapname = $field;
			if ( $ldapname =~ s/_(\w)/uc($1)/ge ) {
				$data{fields}->{$ldapname} =  $data{fields}->{$field};
				delete $data{fields}->{$field};
			}
		}
		
		foreach my $field (keys %{$data{fields}}) {
			next unless $field;
			next if ($data{fields}->{$field} eq '' && 
				 !($field eq 'value'));
			if ((exists $this->{accept_attribute} &&
				 $field !~ /$this->{accept_attribute}/) or
				(exists $this->{reject_attribute} &&
				 $field =~ /$this->{reject_attribute}/)) {
				debug "db $item" => "reject $field";
				next;
			}

 			$modify_data{$field}=$data{fields}->{$field};
			push(@{$add_data}, $field);
			push(@{$add_data}, $data{fields}->{$field});
		}

		my @owners = keys %{$data{owners}};
		debug "db $this->{name}" => "owners is ".join("  ", @owners);
		$modify_data{owners} = \@owners;
		push(@{$add_data}, 'owners');
		push(@{$add_data}, \@owners);
		
		my @flags = grep { $data{flags}->{$_} eq 'true' } keys %{$data{flags}};
		if (@flags) {
			$modify_data{flags} = \@flags;
			push(@{$add_data}, 'flags');
			push(@{$add_data}, \@flags);
		}

		$modify_data{variables} = [];
		foreach my $var (keys %{$data{variables}}) {
			my $variable = "$var=$data{variables}->{$var}";
			push (@{$modify_data{variables}}, $variable);
			push(@{$add_data}, 'variables');
			push(@{$add_data}, $variable);
		}
		
		my $rv="";
		my $op;
		if ($this->{exists}->{$item}) {
			$op = 'Modify';
			$rv = $this->{ds}->modify($entry_dn, replace => \%modify_data);
		} else {
			$op = 'Add';
			$rv = $this->{ds}->add($entry_dn, attrs => $add_data);
		}
		if ($rv->code) {
			$this->error("$op failed for $entry_dn: ".$rv->error);
		}

		delete $this->{dirty}->{$item};
	}
}


1

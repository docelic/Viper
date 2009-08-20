package Viper;
$Viper::VERSION= '.1p610'; # Thu Aug 20 01:57:28 CEST 2009
#
# vim: se ts=2 sts=2 sw=2 ai
#
# Viper -- Custom Perl backend for use with the OpenLDAP server.
#
# Spinlock Solutions --
#   Advanced GNU/Linux networks in commercial and education sectors.
#
# Copyright 2008-2009 SPINLOCK d.o.o., http://www.spinlocksolutions.com/
#                     Davor Ocelic, docelic@spinlocksolutions.com
#
# http://www.spinlocksolutions.com/
# http://techpubs.spinlocksolutions.com/
#
# Released under GPL v3 or later.
#
# The Viper backend implements regular LDAP functionality and can be used in
# general-purpose LDAP scenarios where you want quick results on a platform
# that already has extra features (default entries, query rewriting, dynamic
# values, etc.), and also lends itself to further custom functionality.
#
# However, it's main role is serving as the backend for automatic system
# installations and configurations, where the clients are Debian-based
# systems retrieving configuration data using HTTP preseeding, Debconf and
# its LDAP driver, and in a final stage Puppet.
# A whole set of features has been implemented specifically for this purpose.
#
# Viper homepage: http://www.spinlocksolutions.com/viper/
# Git repository: http://www.github.com/docelic/Viper/
# Mailing list:   https://lists.hcoop.net/listinfo/viper-users
#
# Quick look at configuring a suffix using Viper backend:
# (shown is a minimal setup, without any interesting or Viper-specific
# features. For full configuration options, see Viper documentation)
#
# modulepath  /usr/lib/ldap
# moduleload  back_perl
# 
# database        perl
# suffix          "dc=spinlock,dc=hr"
# perlModulePath  "/etc/ldap/viper/"
# perlModule      "Viper"
# directory       "/var/lib/ldap/viper"
#
# # If needed:
# rootdn          cn=admin,dc=spinlock,dc=hr
# rootpw          nevairbe
#

use strict;
use warnings;
use IO::File            qw//;
use Data::Dumper        qw/Dumper/;
use File::Find::Rule    qw/find/;
use Net::LDAP::Constant qw/LDAP_SUCCESS LDAP_PARAM_ERROR LDAP_OPERATIONS_ERROR/;
use Net::LDAP::Constant qw/LDAP_ALREADY_EXISTS LDAP_NO_SUCH_OBJECT LDAP_OTHER/;
use Net::LDAP::Constant qw/LDAP_INVALID_SYNTAX LDAP_INVALID_DN_SYNTAX/;
use Net::LDAP::Constant qw/LDAP_NOT_ALLOWED_ON_NONLEAF LDAP_FILTER_ERROR/;
use Net::LDAP::Constant qw/LDAP_INVALID_CREDENTIALS/;
use Net::LDAP::Constant qw/LDAP_TIMELIMIT_EXCEEDED LDAP_SIZELIMIT_EXCEEDED/;
use Net::LDAP::LDIF     qw//;
use Net::LDAP::Schema   qw//;
use Net::LDAP::Filter   qw//;
use Net::LDAP::FilterMatch qw//;
use Storable            qw/freeze nstore retrieve/;
use File::Path          qw/rmtree/;
use Fcntl               qw/:flock/;
use Net::LDAP           qw//;
use Text::CSV_XS        qw//;
use Memoize::Expire     qw//;
use List::MoreUtils     qw/any firstidx/;

use subs                qw/p pd pc pcd/;

# To make use of DEBUG, server must run in foreground mode. Something like:
# su -c 'LD_PRELOAD=/usr/lib/libperl.so.5.10 /usr/sbin/slapd -d 256'
use constant DEBUG    => 0; # General debug?
use constant DEBUG_DTL=> 0; # Detailed debug?
use constant DEBUG_OVL=> 0; # Overlays debug?
use constant DEBUG_CCH=> 0; # Cache debug?

use constant CFG_STACK=> 1; # Allow save/reset/load config file routines
use constant CFG_DUMP => 1; # Allow savedump/loaddump config file routines

# Enable/disable options
use constant APPENDER => 1; # Enable appending with other entries' attributes.
use constant FILEVAL  => 1; # Enable value expansion by reading files.
use constant EXPANDVAL=> 1; # Enable value expansion by loading DN attrs.
use constant FINDVAL  => 1; # Enable re-searching and returning certain attr.
use constant PERLEVAL => 0; # Enable Perl evaluation of values. *DANGEROUS*

use constant RELOCATOR=> 0; # Enable relocation of Debconf keys from client.
use constant PROMPTER => 0; # Enable relocation of Debconf keys from server.
use constant CACHE    => 1; # Enable specifying cache parms for overlay values?

# Search scope defines
use constant BASE     => 0;
use constant ONE      => 1;
use constant SUB      => 2;
use constant CHILDREN => 3;

# Referral chasing
use constant NEVER    => 0;
use constant ALWAYS   => 1;
use constant SEARCH   => 2;
use constant FIND     => 3;

BEGIN {
	# No need to initialize the whole Debconf block if prompter is off.
	# (This allows server to run on non-debian machine as long as you do
	# not require server-side/debconf prompting).
	return if !PROMPTER;

	$ENV{DEBCONF_SYSTEMRC}= '/etc/debconf.conf.pipe';
	require 'Debconf/Db.pm';
	require 'Debconf/Config.pm';
	require 'Debconf/AutoSelect.pm';
	require 'Debconf/Format/822.pm';
	require 'Debconf/DbDriver/LDAP.pm';
	Debconf::DbDriver::LDAP->import( qw/parse_records/);
}

# Raw/binary value regex
our $RAW              = qr/(?i:^jpegPhoto|;binary)/;

# LDAP scope to fs tree depth level
our %S2L= (
	1 => 1,     # ONE      (1 level)
	2 => undef, # SUB      (unlimited)
	3 => undef, # CHILDREN (unlimited)
);

# Overlays that will run on an entry if individual
# overlay is enabled. Name here should match the name of overlay's
# config array (see sub new()'s $this object) and in turn it is also
# name by which overlay will be recognized by run_overlays() within
# attribute's values.
our @OVERLAYS= ( grep { defined $_ } (
	FILEVAL    ? 'file'   : undef,
	EXPANDVAL  ? 'exp'    : undef,
	FINDVAL    ? 'find'   : undef,
	PERLEVAL   ? 'perl'   : undef,
));

# Necessary variables for Debconf interaction and server-side prompting.
#  cin/out, tin/out: config DB in/out pipe, templates DB in/out pipe, used
#   for initializing prompter's debconf state.
#  dc/t/f/m: references to debconf's config/templates/frontend/confmodule.
our ( $cin, $cout, $tin, $tout);
our ( $dc, $dt, $df, $dm);


# Backend instance
sub new {
	my( $class)= @_;

	p "NEW @_ ----------------------------------------";

	# Assign instance defaults. List all allowed options here,
	# even if their value is '' or 0. (Do not use undef if you expect to
	# set it from the config file because it will implicitly make the
	# option invalid).
	# Scalars get values assigned, arrays pushed, hashes arrayref'd.
	my $this= {
		treesuffix     => q{},     # Suffix (too bad we're not called with it),
		                           # and 'suffix' directive can only be specified
		                           # before Viper.pm module so we can't get that
		                           # one from slapd. We basically have to invent
		                           # a new directive and set it to the same value.
		directory      => q{},     # Base directory / datadir for tree. Can be
		                           # different for each suffix, but suffixes when
		                           # in the same directory can use each other's
		                           # fallback/default values etc.
		extension      => '.ldif', # Extension for leaf nodes (files). Can be set
		                           # to anything, but .ldif is usually most
		                           # reasonable. Note that you cannot go without
		                           # extension as that makes files and directories
		                           # indistinguishable, and breaks the server.

		addoverwrites  => 0,       # Allow ADD to overwrite existing entries?
		addignoredups  => 0,       # If overw=0, ignore ADD on existing entries?
		addrelocate    => {},      # name=>[$a,$b] for $name==loc && $dn=~ s/$a/$b/
		addprompt      => {},      # Run prompter under name, cfg->tpl=~ s/$a/$b/


		modifysmarts   => 1,       # Allow MODIFY to detect no-change
		modifycopyonwrite=> 1,     # Modify & copy dfl entry to new DN if !exist?

		deletetrees    => 1,       # DELETE allows deleting of non-leafs?

		searchsubst    => [],      # List of [...->...] search subst rules
		searchfallback => [],      # List of [$a,$b] for $dn or $dn=~ s/$a/$b/
		entryappend    => [],      # List of [$a,$t,$b,$p,$n] to append with attrs

		# All directives below are in form [ [$m, $nm], ... ], where $m and
		# $nm are regexes that attribute name must match and NOT match (respe-
		# ctively) for the overlay to execute on its values.
		perl           => [],      # Match/No-Match regex list for perleval
		'exp'          => [],      # Match/No-Match regex list for expandval
		file           => [],      # Match/No-Match regex list for fileval
		'find'         => [],      # Match/No-Match regex list for findval

		overlayconfig  => {},      # default overlay opts ('OVLNAME|default SPEC')
		cacheopen      => '',      # cache spec for dn2leaf's results

		schemaldif     => [],      # Schema in LDIF format (to be aware of schema).
		                           # To produce schema file, start server, then use
		                           # schema.pl to retrieve schema from server in
		                           # LDIF format and dump it to a file.
		schemafatal    => 0,       # Missing schema is fatal problem? (Allowed to be
		                           #  missing by default so that you can run server,
		                           #  get schema, save it and have it on next start)

		# Keys that control parsing behavior in slapd.conf and basically take
		# effect directly when encountered.

		message        => q{},     # Print message to console

		var            => {},      # Define a variable, var NAME "V A L"
		parse          => 1,       # Parse vars in following cfg lines (yes/no)

		clean          => q{},     # Clean temp/stack files in $directory/tmp/
		save           => q{},     # Save current cfg stack to named file
		'reset'        => q{},     # Clean cfg stack currently in memory
		load           => q{},     # Load cfg stack from a named file
		'savedump'     => q{},     # Storable dump to named file (for standalone)
		'loaddump'     => q{},     # Storable load from named file (for standalone)

		# Keys that will contain data generated on startup or during run

		schema         => undef,   # Will contain schema (load with 'schemaLDIF')
		tmpdir         => undef,   # $directory/tmp, hardcoded
		stack          => [],      # Current config stack, can 'save' or 'reset' it

		standard_parse => undef,   # Text::CSV_XS obj. for parsing various input
		level          => 0,       # Loop/depth count. Usually 1
		ovl_cache      => {},	     # Will contain queues with cached ovl values
		dn2leaf_cache  => {},	     # Will contain queues with cached dn2leaf values
		op_cache_valid => {},      # Num-ops cache validity

		'start'        => [],      # Time of search start (array ID= search level)
	};

	# Must be done here as schema parser already has to be present
	# during config parsing step.
	$this->{schema}= new Net::LDAP::Schema;

	bless $this, $class
}


# Called after all configuration processing is over
sub init {
	my( $this)= @_;

	p "INIT @_ $this->{treesuffix}";

	# Let's do some checking.

	# Make sure 'extension' is non-empty. (As to why, read note on
	# 'extension' above).
	if( not $this->{extension}) {
		warn 'File extension for leaf nodes cannot be empty; ' .
			"set a value (such as '.ldif') and restart slapd.\n";
		return LDAP_PARAM_ERROR
	}

	# Now ensure that the root of the configured tree exists. To do that,
	# all we need to do is create the components on the way to final
	# component.
	# Actually, for now, just verify the paths are there, if not, throw
	# warning.

	my $dn= $this->{treesuffix};

	$dn=~ s/^.+?,\s*//; # Reduce DN to part of the path that needs to be there
	
	my( $ret, %ret);

	# Note: this doesn't bail out on File not found because dn2leaf is called
	# with namesonly param, so no actual checking is done.
	$ret= $this->dn2leaf( "$dn", \%ret, qw/namesonly 1/);
	return $ret unless $ret== LDAP_SUCCESS;

	# Note: $dn=~ check is here to avoid the error message on 
	# suffixes with a single component (such as ou=defaults)
	if( $dn=~ qr/,/o and not -e $ret{file}) {
		warn 'Components leading up to the tree suffix '.
		"for $this->{treesuffix} are missing; ".
			"create them and restart slapd.\n";
		return LDAP_OPERATIONS_ERROR
	}

	## Now make symlinks for all virtual paths, unless present already.

	#my( $ret, %ret);

	## Figure out our basedir where symlinks are to be created
	## (dc=tmp is added here brutally like this so that $ret{directory} shows
	## the directory we want, not one level too low).
	#$ret= $this->dn2leaf( "dc=tmp,$this->{treesuffix}", \%ret, qw/namesonly 1/);
	#return $ret unless $ret== LDAP_SUCCESS;

	## XXX Error ckin
	#mkpath $ret{directory};

	#for my $virtual_line( @{ $this->{virtual}}) {
	#	for my $virtual( @$virtual_line) {
	#		$ret= $this->dn2leaf( "dc=tmp,$virtual", \%ret, qw/namesonly 1/);
	#		return $ret unless $ret== LDAP_SUCCESS;

	#		warn " VIRTUAL $virtual, PATH $ret{directory} / $ret{file}\n";
	#	}
	#}

	# Initialize schema obj. We do that in new(), but add ||= check here
	# for situations where Viper is ran standalone using config dump from
	# file, where references to objects are of course lost.
	$this->{schema}||= new Net::LDAP::Schema;

	# Debconf-related init code
	$this->debconf_initialize if PROMPTER;

	# Initialize Text::CSV_XS parser suitable for generic use
	$this->{standard_parse}= Text::CSV_XS->new({
		# We better use default escape_char and not \ because it's VERY
		# confusing. (It's already too confusing that you DO have to write
		# \\ instead of just \ in slapd.conf, but you DO NOT do that when
		# a value is in LDIF source). So let's not add another layer of
		# confusion -- the default escape char (" - literal double quote)
		# probably works fine.
		#escape_char      => q{\\},
		sep_char         => q{ },
		binary           => 1,
		# Unfortunately, this option does not result in us being able to use
		# multiple spaces (probably due to sep_char also being whitespace).
		#allow_whitespace => 1,
	});

	LDAP_SUCCESS
}


# Called to verify bind credentials.
# Note that this function is called only when it is an
# authenticated bind AND rootpw for the suffix in slapd.conf
# is not set. If the bind DN matches rootdn in slapd.conf
# and rootpw is set, then slapd does the verification itself
# (matching password against rootpw) and does not trigger
# this function.
sub bind {
	my( $this, $dn, $pw)= @_;

	$this->normalize( \$dn);

	p "BIND $dn"; # Do not show $pw in log.

	my ( $ret, undef, undef, $entry)= $this->load( $dn);
	return LDAP_INVALID_CREDENTIALS unless $ret== LDAP_SUCCESS;

	my @pws= $entry->get_value( 'userPassword');

	# See if any userPassword (can be multi-value) matches
	# the provided password
	if( any { "$pw" eq "$_" } @pws) {
		return LDAP_SUCCESS
	}

	LDAP_INVALID_CREDENTIALS
}


# Handle our config lines. Called by slapd for each directive.
sub config {
		my( $this, $key, @val)= @_;

		$key= lc $key;

		p "CONFIG $key @val";

		# Support config file to specify longer names of config options for
		# clarity. Internally, we use short names. I.e. a config line of 
		# "expandval opt1 opt2" is translated to "exp" internally.
		# (But you can also specify 'exp' directly (or anything in between)).
		if(!( defined $this->{$key})) {
			my @keys;
			for my $cfgkey( keys %$this) {
				push @keys, $cfgkey if $key =~ /^$cfgkey/
			}
			if( @keys== 1) { # Great, uniquely found the right key
				p "Resolved config key '$key' to '$keys[0]'";
				$key= $keys[0];

			} elsif( @keys> 1) {
				warn "Ambiguous config directive '$key' (@keys)\n";
				return LDAP_PARAM_ERROR

			} elsif( @keys== 0) {
				warn "Unknown config directive '$key'\n";
				return LDAP_PARAM_ERROR
			}
		}

		# Push config line, barely processed, to the config stack
		# (Note: but not if it's one of the save/load/reset/etc commands).
		push @{ $this->{stack}}, [ $key, @val] if
			$key ne 'save' and $key ne 'reset' and $key ne 'load' and
			$key!~ qr/dump$/o;

		# Apply generic changes/replacements we do for every line and
		# field. (Basically just a series of convenience helpers).
		for( @val) {

			# Parse/expand variables if parsing currently enabled.
			# ${var} expands to variables, %{directive} to values of
			# scalar config directives.
			if( $this->{parse}) {
				s/\$\{(\S+?)\}/$$this{var}{$1}[0]/g;
				s/\%\{(\S+?)\}/$$this{$1}/g;
			}
		}

		# Very simple: if we know about this key, allow it. If not, throw a fit.
		unless( defined $this->{$key}) {
			return LDAP_PARAM_ERROR
		}

		# Now handle config directives that call for immediate work as soon
		# as they're encountered:

		if( $key eq 'message') {                    # MESSAGE
			warn 'Message: ', join( ' ', @val), "\n"

		# XXX instead of specifying schema file, also allow online discovery
		# and load of schema. (connects to server, retrieves it, loads).
		} elsif( $key eq 'schemaldif') {            # SCHEMA LDIF
			my $schema= $this->{schema};

			for( @val) {
				p "Parsing schema file '$_'";

				unless( $schema->parse( $_)) {
					my $error= $schema->error;
					warn "Error parsing schema '$_' ($error)\n";

					return LDAP_OPERATIONS_ERROR if $this->{schemafatal}
				}
			}

		} elsif( $key eq 'var') {                   # SET VARIABLE
			for( my $i= 0; $i< @val; $i+= 2) {
				$this->{var}{$val[$i]}= [ $val[$i+1]];
			}

		} elsif( $key eq 'reset' and CFG_STACK) {   # RESET STACK
			$this->{stack}= undef

		} elsif( $key eq 'save' and CFG_STACK) {    # SAVE STACK
			for( @val) {
				s/[^\w\.]//g; # allow only [\w\.]+ in filename
				s/^\.//; # delete all '.' prefix on the filename

				# XXX idea: generic write routine that knows how to write
				# plain file, entry, and ldif
				my $ret= $this->write_file(
					$this->{tmpdir}, $_, Dumper $this->{stack});
				return $ret unless $ret== LDAP_SUCCESS;
			}

		} elsif( $key eq 'load' and CFG_STACK) {    # LOAD STACK

			# In load specification, the first argument is the filename. The rest,
			# if present, is a list of PATTERN REPLACEMENT to perform
			# on each stored line before sending it to the config processor.
			$_= shift @val;
			my $orig_fn= $_;

			s/[^\w\.]//g; # allow only [\w\.]+ in filename
			s/^\.//; # delete all '.' prefix on the filename

			if( $orig_fn ne $_) {
				p "Stack load filename sanitized to '$_'";
			}

			# Evaluate Dumper data that we read in
			my $edata;
			{
				use vars qw/$VAR1/;
				my( $ret, @data)= $this->read_file( $this->{tmpdir}, $_);
				return $ret unless $ret== LDAP_SUCCESS;

				my $data= join q{}, @data;
				$edata= eval $data;

				if( $@) {
					warn "Error loading stack file '$_' ($@)\n";
					return LDAP_OPERATIONS_ERROR
				}
			}

			if( defined $edata) {
					if( ref $edata ne 'ARRAY') {
					warn "Loaded stack file '$_', but it's not an arrayref!\n";
					return LDAP_OPERATIONS_ERROR
				}

				# List of substitutions to perform on each line and each
				# argument before sending everything to the config processor.
				my %substs= @val;

				# Now send line by line to the config routine
				for my $line( @$edata) {

					# Perform any substs specified as 'load FILE PAT REPL...':
					for my $arg( @$line) {
						while( my( $p, $r)= each %substs) {
							$arg=~ s/$p/$r/g;
						}
					}

					$this->config( @$line)
				}
			} else {
				warn "Empty stack file '$_'. Configuration mistake?\n"
			}

		} elsif( $key eq 'clean' and CFG_STACK) {   # DELETE OLD STACK FILES

			unless( $this->{tmpdir}) {
				warn "Called 'clean' before 'directory' has been set\n";
				return LDAP_OPERATIONS_ERROR
			}
			
			my $glob= join '/', $this->{tmpdir}, '*';
			for my $file( glob $glob) {
				p "Unlinking tmp stack file '$file'";
				unless( unlink $file) {
					warn "Can't unlink tmp stack file '$file' ($!)\n";
					return LDAP_OPERATIONS_ERROR
				}
			}

		} elsif( $key eq 'savedump' and CFG_DUMP) { # SAVE DUMP
			for( $val[0]) {
				if( not my $ret= nstore $this, $this->{tmpdir}. '/'. $_) {
					return $ret unless $ret== LDAP_SUCCESS;
				}
			}

		} elsif( $key eq 'loaddump' and CFG_DUMP) { # LOAD DUMP
			my $ret;

			for( $val[0]) {
				if( not $ret= retrieve $this->{tmpdir}. '/'. $_) {
					return $ret unless $ret== LDAP_SUCCESS;
				}

				# Load all keys into $this and effectively restore state
				%$this= %{ $ret};
			}
		}

		# Now generic, regular handling of the config keys:

		# NOTE: this will happen for "dynamic" options as well (i.e.
		# reset/load/save/message etc.), which don't have any benefit from
		# that processing. But we don't particularly care about that; we still
		# do it, and we just have a side-effect that we remember the name of
		# last saved/loaded stack, message printed etc. This might even show
		# handy once in the future.

		# If key is defined as arrayref, push [a, b, ...] onto it;
		# If key is defined as hashref, do name= [a, b, ...];
		# Otherwise, perform regular scalar assignment.
		if( ref $this->{$key} eq 'ARRAY') {
			push @{ $this->{$key}}, [ @val]

		} elsif( ref $this->{$key} eq 'HASH') {
			my $locname= shift @val;
			$this->{$key}{$locname}= [ @val];

		} else {
			$this->{$key}= join ' ', @val
		}

		# Now post-handling of options:

		# When directory is defined, create tmp/ inside of it to use
		# as a temporary directory store for save/load commands.
		if( $key eq 'directory') {
			$this->{tmpdir}= join '/', $this->{directory}, 'tmp';

			if( ! -e $this->{tmpdir} or ! -d $this->{tmpdir}) {
				unless( mkdir $this->{tmpdir}) {
					warn "Can't mkdir '$this->{tmpdir}' ($!)\n";
					return LDAP_OPERATIONS_ERROR
				}
			}
		}

		LDAP_SUCCESS
}


# Adding entries
sub add {
	my( $this, $ldif)= @_;

	my( $ret, $entry)= $this->ldif2e( \$ldif);
	return $ret unless $ret== LDAP_SUCCESS;

	#
	# LDIF now as ENTRY, do any changes
	#

	# Normalize DN
	$this->normalize( $entry);

	#
	# Save ENTRY
	#

	my $dn= $entry->dn;

	DEBUG and p "ADD '$dn': " . ( Dumper \$ldif);

	# XXX Check for validity of attrs in entry. (Well, I think
	# slapd does that, no worries, all we get here is valid)

	$ret= $this->save( $dn, $entry);
	return $ret unless $ret== LDAP_SUCCESS;

	#
	# See if there's work for relocator.
	#

	if( RELOCATOR) {
		$ret= $this->check_relocation( $entry);
		return $ret unless $ret== LDAP_SUCCESS;
	}

	#
	# See if there's work for server-side prompter.
	#

	if( PROMPTER) {
		$ret= $this->check_prompter( $entry);
		return $ret unless $ret== LDAP_SUCCESS;
	}

	LDAP_SUCCESS
}


# Searching for entries
sub search {
	my $this= shift;

	$this->check_state( \@_);

	my( %req, @attrs); 
	( @req{qw/base scope deref size time filter attrOnly/}, @attrs)=@_;

	# Explanation of input parameters:
	#
	# BASE search base
	# SCOPE (0-3) base, one, sub, children
	#   base: just the one
	#   one: 1-level sub, no base
	#   sub: base + sub
	#   children: sub, no base
	# DEREF (0-3) never, always, search, find
	#   search: only on search
	#   find: only the base object
	# TIMELIMIT: secs, 0 - unlimited, max - max
	# SIZELIMIT: nr. entries limit. 0 -unlimited, max - max
	# FILTER: dfl (objectClass=*)
	# ATTRONLY - attributes only, no values
	# @ATTRS list of attrs to return, special: */null = all, + = operational

	# Normalize base DN
	$this->normalize( \$req{base});

	p "SEARCH ($this->{level}) @_";

	#
	# Let's see if we have to do any substitution on input params. Substitution
	# via subst allows one to match arbitrary parameters of the search
	# request, and if all of them satisfy, then perform specified substitutions
	# on the params.
	#

	my( $id, $i, $ok, $k, $v, $r, @stack)= ( 0);
	for my $rule( @{ $this->{searchsubst}}) {
		$id++;

		( $i, $ok, $k, $v, $r)= ( 0, 1, undef, undef, undef); # Clear vars
		$#stack= -1; # Clear stack

		# Phase 1: see if all subst conditions match
		do {
			# XXX error ckin, make sure $i/$i+1 are valid
			( $k, $v)= ( $$rule[$i], $$rule[$i+1]);

			# If rule matches, save eventual matches to @stack
			if( $req{$k}=~ /$v/) {
				push @stack, [ $1, $2, $3, $4, $5, $6, $7, $8, $9];

			} else {
				p "SEARCH SUBST #$id skipped ($k!~ /$v/)";
				$ok= 0;
			}

		} while( $ok and $i+= 2 and $$rule[$i] ne '->');

		next if !$ok; # if this rule doesn't match, search further

		# Phase 2: now we know all conditions matched, so perform actual substs
		p "SEARCH SUBST #$id matched '@$rule'";
		$i++; # Skip the '->' marker

		do {
			( $k, $v, $r)= ( $$rule[$i], $$rule[$i+1], $$rule[$i+2]);
			$v=~ s/(?<!\\)\$\[(\d+)\]\[(\d+)\]/$stack[$1][$2]/g;
			$r=~ s/(?<!\\)\$\[(\d+)\]\[(\d+)\]/$stack[$1][$2]/g;

			$req{ $k}=~ s/$v/$r/; # <- substs performed here (/g needed?)

			p "SEARCH SUBST #$id action $k=~ s/$v/$r/ RESULT $req{ $k}";

		} while(
			$i+= 3
			and defined $$rule[$i]
			and defined $$rule[$i+1]
			and defined $$rule[$i+2]
		);
	}

	# Now, continue as normal as if nothing ever happened

	# Save original requested base. (Need to have it, unmodified, for proper
	# expansion of "." (dots) in DN specifications). Note that this is the
	# base AFTER rewriting.
	$req{origbase}= $req{base};

	# We were letting OpenLDAP handle filtering with filterSearchResults
	# directive, but that wasn't optimal because we weren't able to modify
	# search filter. Now we do filtering ourselves and we can do
	# anything we want anywhere we want (with filter and all other search
	# params), producing only final results for passing back onto slapd.
	my $filter;
	unless( $filter= Net::LDAP::Filter->new( $req{ filter})) {
		warn "Invalid filter '$req{ filter}'\n";
		return LDAP_FILTER_ERROR
	}

	my @matches= ();

	my( $ret, $newbase, %ret);
	my( $ldif, $entry);

	# slapd expects results in LDIF, but our internal subinvocations basically
	# always want entry results, not LDIF. So, in a direct call from slapd,
	# $as_ldif will be true, otherwise false (implying we want entry objects).
	my $as_ldif= $this->{level}== 0? 1: 0;

	# First entry is always the base, if -s base or -s sub was specified
	# for search scope.
	if( $req{scope}== BASE or $req{scope}== SUB) {

		# origdn is the original DN, which will be used for "." (dots" expansion
		# in DN specs (i.e. cn=abc...)
		( $ret, $newbase, $ldif, $entry)=
			$this->load( $req{base}, qw/entry 1 ldif 1/, 'origdn', $req{origbase});
		return $ret unless $ret== LDAP_SUCCESS;

		# If original search base was found, this is a no-op. Otherwise
		# $newbase is some fallback base found and we "switch" to it.
		$req{base}= $newbase;

		# We unshift because on return from Perl to ldap, data is read
		# in reverse order.
		if( $filter->match( $entry)) {
			DEBUG and p 'SEARCH MATCH:', $entry->dn;
			unshift @matches, $as_ldif? $ldif: $entry;

			goto SIZE_LIMIT if @matches> $req{size};
		}

		my $time= time;
		goto TIME_LIMIT if any { $time- $_> $req{time}} @{ $this->{start}}
	}

	# Further entries may follow unless only base was specifically
	# requested with -s base
	if( $req{scope}!= BASE){
		my $level= 0;

		( $ret, $req{base})= $this->resolve( $req{base}, \%ret, qw/leaf 0/);
		return $ret unless $ret== LDAP_SUCCESS;

		my $dir= $ret{directory};
		my $md= $S2L{$req{scope}};

		# Use File::Find::Rule to traverse the directory tree selectively
		# and scoop out what we want.
		File::Find::Rule->file()
			->name( '*'. $this->{extension})
			->extras({ follow => 1})
			->exec( sub {
					# Note that here we don't pass origdn onto load(). If a specific
					# search base is known and requested, we take that as origdn
					# (such as shown above). But if we go into tree subsearch,
					# then each time we use DN of the entry found (treating it
					# as a specific search base).
					( $ret, undef, $ldif, $entry)= $this->load(
						$_[2], qw/dnasfile 1/);

					return $ret unless $ret== LDAP_SUCCESS;
					if( $filter->match( $entry)) {
						DEBUG and p 'SEARCH MATCH:', $entry->dn;
						unshift @matches, $as_ldif? $ldif : $entry;

						goto SIZE_LIMIT if @matches> $req{size};
					}

					my $time= time;
					goto TIME_LIMIT if any { $time- $_> $req{time}} @{ $this->{start}}
			} )
			->maxdepth( $md)
			->readable
			->in( $dir)
	}

	$ret= LDAP_SUCCESS;
	goto SEARCH_DONE;

	TIME_LIMIT:
	$ret= LDAP_TIMELIMIT_EXCEEDED;
	goto SEARCH_DONE;

	SIZE_LIMIT:
	$ret= LDAP_SIZELIMIT_EXCEEDED;

	SEARCH_DONE:

	my ( $level, $start)= ( $this->{level}, $this->{start}[ $this->{level}]);

	p 'SEARCH TOTAL:', scalar @matches, 'matches ('.
		"level $level, time=". ( time- $start). "/$req{time}, ".
		"size=". ( scalar @matches). "/$req{size})";

	$this->{level}-= 1;

	# $ret will be 0 (LDAP_SUCCESS) if no limits were hit.
	( $ret, @matches)
}


# Modifying existing entries
sub modify {
  my( $this, $dn, @list)= @_;
	my $ldif;

	$this->check_state( \@_);

	# Normalize DN
	$this->normalize( \$dn);

	DEBUG and p "MODIFY '$dn': " . ( Dumper \@list);

	my( $ret, $newdn, %ret, $fh, $entry, $orig);

	# Load existing entry. In the beginning, this was done with load() so
	# that all dynamic work is honored. However, that approach has a problem:
	# entry is appended with attributes from the default entry (if any), then
	# modified and saved back to disk. So if you had an entry with 5
	# regular and 10 appended attributes, and you modify one of those 5, you
	# end up with that one modified, and the other 10 copied and added without
	# your control (instead of having them kept away in the default entry).
	# So what we do now is:
	# - load with resolve() which does not expand or run overlays
	# - modify entries
	# - save back to disk.
	# If it happens that a person modifies one of the attributes that came
	# in via append, we open another copy of the entry (entry2), this time with
	# load(), import the missing value from it (for absolute transparency),
	# and then let modify continue. In that case, the modified attribute
	# would end up in the original entry, copied over and then modified.

	( $ret, $newdn)= $this->resolve( $dn, \%ret, 'entry', 1);
	return $ret unless $ret== LDAP_SUCCESS;

	( $entry, $fh)= @ret{qw/entry fh/};

	$orig= $entry->clone; # For comparison when modifysmarts==1

	# Indicator whether we opened another copy of the entry with load()
	# and placed it in $entry2.
	my $loaded= 0;
	my $entry2;

	# Perform changes on the in-memory entry
  while ( @list > 0) {
		my( $action, $key)= ( shift @list, shift @list);

		my @values;
		while ( @list) {
			# Ignore undefined values. If a key had only one value and it was
			# undefined, it'll get deleted due to if( scalar @values) check below.
			if( defined $list[0]) {
				if( $list[0] !~ qr/^(ADD|DELETE|REPLACE)$/o) {
					my $attr= shift @list;
					push @values, $attr;

					# Make sure that the attr we will operate on exists in the
					# entry. Actually, if it's not there, we just try to load it
					# from $entry2 and continue (it's still possible that it won't
					# exist even after that). No error checking is done here, as
					# that'll be handled by the actual modification routine below.
					if( !$entry->exists( $attr)) {
						# If we didn't load() yet, do it now. Note that this could be
						# done more cleanly outside of the loop, but we don't want to
						# open every entry twice unless there's a real need to operate
						# on entry2.
						if( !$loaded) {
							( $ret, undef, undef, $entry2)= $this->load( $dn, qw/entry 1/);
							return $ret unless $ret== LDAP_SUCCESS;
						}

						# Now, if the attribute does exist in $entry2, it means it's
						# one of the appended attributes, so we add it to $entry, and
						# the actual modification routine below can operate on it
						# flawlessly.
						# We also don't need to worry that get_value() will return an
						# empty list because we have the exists() check.
						if( $entry2->exists( $attr)) {
							$entry->add( $attr=> $entry2->get_value( $attr));
						}
					}

				} else {
					last
				}
			} else {
				shift @list
			}
		}

		$action= lc $action;
		next unless $key;

		if( scalar @values) {
			if(!( $entry->$action( $key, [@values]))) {
				warn "Unable to perform $action($key, ...) on '$newdn'\n";
				return LDAP_OPERATIONS_ERROR
			}
		}
		else {
			# If there are no values, delete key
			if(!( $entry->delete( $key))) {
				warn "Unable to perform delete($key) on '$newdn'\n";
				return LDAP_OPERATIONS_ERROR
			}
		}
	}

	# Changes to the in-memory entry have been performed correctly.
	# We can now remove the old entry and create a new one.
	# NOTE: we do NO-OP if modifysmarts==1 and entry is the same after
	# change. (Debconf submits MODIFY lines for every requested key even
	# if no values actually changed in it, so detecting this is great).
	my $changed= 1;

	# For comparison, set DN of old and new entry to be equal as that is not
	# the point of difference we care about.
	$entry->dn( $dn);
	$changed= 0 if $this->{modifysmarts} and $this->dequal( $entry, $orig);
	$entry->dn( $newdn);

	# If changed (true if we have (1) any request, or (2) modifySmarts== 1
	# and real change has been detected.)
	if( $changed) {

		# If entry existed already, no probs.
		# But if it is changed and does not exist (i.e. it comes from a fallback)
		# then we look up config option modifyCopyOnWrite. When 1, modification
		# is performed and entry is saved to where it belongs (we create&modify it)
		# However, if modifyCopyOnWrite is 0, we return LDAP_NO_SUCH_OBJECT.
		if( $newdn ne $dn) {
			if( $this->{modifycopyonwrite}) {
				p "MODIFY AND COPY '$newdn' to '$dn'"
			} else {
				p "MODIFY WON'T WORK ON FALLBACK NOR CREATE '$dn' ".
					'(modifyCopyOnWrite == OFF)';
				return LDAP_NO_SUCH_OBJECT
			}
		}

		$ret= $this->dn2leaf( $dn, \%ret);
		return $ret unless $ret== LDAP_SUCCESS;
		$this->save( $dn, $entry, qw/overwrite 1 modify 1/);
	}

	$this->{level}-= 1;

	LDAP_SUCCESS
}


# Deleting entries
sub delete {
	# XXX Make perl backend actually pass various delete options onto us.
	# (-r not possible currently because we don't receive any parms, so
	# whether non-leaf delete is allowed is controled with 'deletetrees' option)
	my( $this, $dn)= @_;

	# Normalize DN
	$this->normalize( \$dn);

	DEBUG and p "DELETE '$dn'";

	my( $ret, %ret);

	# For now, this function is deleting actual entries, not taking into
	# account various fallbacks etc. So it means it's possible to get
	# NO_SUCH_OBJECT error on delete even if you get the value when you
	# search for it. Let's see how that works in practice for a while and if
	# it needs a change or not.
	# And this is also consistent with ADD where the entries are also
	# added to specific locations.
	# In any case, to switch to a fallback-aware version (which then deletes
	# the fallback), replace dn2leaf() with resolve() and the same args.
	$ret= $this->dn2leaf( $dn, \%ret, qw/leaf 0 namesonly 1 verify 1/);
	return $ret unless $ret== LDAP_SUCCESS;

	# If entry ain't there in the first place...
	return LDAP_NO_SUCH_OBJECT if !$ret{file} and !$ret{directory};

	if( defined $ret{directory}) {
		if( $this->{deletetrees}) { $ret= rmtree $ret{directory} }
		else                   { $ret= rmdir $ret{directory} }

		if( not $ret) {
			return LDAP_OPERATIONS_ERROR if $!== 13;       # EACCESS
			return LDAP_NOT_ALLOWED_ON_NONLEAF if $!== 39; # ENOTEMPTY
			return LDAP_OTHER
		}
	}

	# $ret{file} should always be defined if we reach here, but if directory
	# exists and file does not, in dn2leaf we don't halt but issue a serious
	# warning and resume processing, so in that case it may be undefined.
	if( defined $ret{file}) {
		unlink $ret{file} or return LDAP_OPERATIONS_ERROR
	}

	LDAP_SUCCESS
}


#
# Our vision of overlays
#

# Overlays have been put together in a single function for excellent
# efficiency, but here are their individual descriptions, in order
# of execution, soonest-first:
#
#  - File expansion overlay.
#  - Values expansion overlay.
#  - Find (subsearch) overlay.
#  - Perl evaluation overlay (*DANGEROUS*, so disabled by default).

# Ok, here's the all-in-one overlay sub. It's a bit nested so hang on
# in there. Each overlay's code is only a few lines in the innermost
# block.
sub run_overlays {
	my( $this, $e, $odn)= @_;

	# Original DN requested. Used in replacing dots (".") at the end of
	# attribute value's DN spec with components from the original entry.
	$odn||= $e->dn;

	for my $a( $e->attributes) {
		next if $a =~ qr/$RAW/o; # Skip attribute if raw/binary

		for my $ovl ( @OVERLAYS) {

			for my $cond( @{ $this->{$ovl}}) {
				if( $a =~ /$$cond[0]/ and $a !~ /$$cond[1]/ ){
					# Ok, we know overlay is configured with at least one line in
					# slapd.conf and that line matches our attribute name.

					DEBUG_OVL and p "OVERLAY $ovl on '$a' due to rule @$cond";

					# XXX this can be moved in the for( $a) loop, and there
					# we can skip processing if there's no '$' in any of the
					# values.
					my @v= $e->get_value( $a);
					my @v2;

					# Implemented via while( defined( shift @v) and not using
					# for( @v) so that one value can result in instantiating
					# multiple values. For that we need to be able to
					# modify @v while iterating through it.
					while( defined( my $v= shift @v)) {

						my @vstack;

						# (Note that we cannot move index() check up to reorganize
						# this, because the code is currently designed that each overlay
						# operates on all attributes and values before moving onto
						# the next.
						# XXX I'm not sure if that's really needed in practice. Even
						# if it is, we can probably save on splitting/putting back
						# the value after each overlay run if we kept the components
						# in an array ad operated on the array. Something to think about
						# for later.
						if( index( $v, '$') != -1) {
							# Ok, there are at least two components in this 
							# attribute's value, so it makes sense for us to run.

							my @comps;
							my @splits= ( []); # (So that indices match)

							# Fill @comps with components split on \s*\$\s*, but 
							# also remember the exact splitter that was used. (For
							# later re-construction of components that we did not
							# modify and for inserting appropriate space before/after
							# the processed components).
							while ( $v =~ qr/(\s*)\$(\s*)/o) {
								my( $pre, $post)= (
									(defined $1 ? $1 : q{}),
									(defined $2 ? $2 : q{}),
								);
								my $c;
								( $c, $v)= split /$pre\$$post/, $v, 2;
								push @comps, $c;
								push @splits, [ $pre, $post]
							}
							push @comps, $v;

							# Now run; loop over all components and see if any has
							# the name of our overlay, and if yes, do whatever the
							# overlay's function is on the next component.
							# (i.e.  "perl $ 3 + 4" ===> "7" )
							my $run= 0;
							my %opts; # Eventual options passed to overlay
							for my $comp( @comps) {
								if( $run) {
									$run= 0;

									# OVERLAY FILEVAL
									if( $ovl eq 'file') { # fileval
										# We want to include file contents
										my( $file, $spec)= split /\s+/, $comp, 2;

										if( $opts{prefix}) {
											$file= $opts{prefix}. $file;
										}

										my $key= join( '|', $file, $spec||'');

										# See if cached value exists. To determine that, as usual
										# with Memoize principle, we'll create a hash key
										# consisting of all our options. It would be phenomenal
										# if we could do it directly at the beginning of overlay
										# but we can't because DN can be specified as say, '...',
										# which expands to different values for different clients.
										# NOTE: We do it only when another DN should be looked up-
										#  for cases where lookup is in the entry itself, we just
										#  do it, don't take that from cache.
										if( $opts{cacheref}) {
											if( exists $opts{cacheref}{$key}) {
												pc "Using cache value for FILE '$key'";
												$comp= $opts{cacheref}{$key};
												goto FILE_DONE
											}
										}

										p 'FILE: will read dir='.  $this->{directory}.
											', file='.  $file.
											', spec='.  ( $spec|| '');

										# Load file contents, end if reading wasn't successful
										my( $ret, @comp)= $this->read_file(
											$this->{directory}, $file, $spec);

										# Comment this if you want even unsuccessful attempts
										# to be cached (empty value).
										if( $ret!= LDAP_SUCCESS) {
											$comp= q{};
											goto FILE_DONE
										}

										$comp= join q{}, @comp;
										chomp $comp if defined $comp;

										# If cacheref exists and $key is there, time for
										# us to save key to cache.
										if( $opts{cacheref} and $key) {
											pc "Rebuilding cache value for FILE '$key'";
											$opts{cacheref}{$key}= $comp
										}

										FILE_DONE:

									# OVERLAY EXPANDVAL
									} elsif( $ovl eq 'exp') { # expandval
										# Ok, we want to expand to some DN's attribute
										my @f= split /\s+/, $comp; # @f== (dn, attr, valx)
										my ( $dn, $attr, $valx, $ret, $ent);
										# If less than 3 args given, we want attr/valx in the
										# current entry and no foreign lookup will be needed.
										if( @f== 1) {
											$ent= $e;
											($attr, $valx)= (@f, 0)

										} elsif( @f== 2) {
											($dn, $attr, $valx)= (@f, 0)

										} elsif( @f== 3) {
											($dn, $attr, $valx)= @f;

										} else {
											p "EXPANDVAL: Invalid specification '$comp'";
											return LDAP_PARAM_ERROR
										}

										my $val_joiner;
										# Support for valx to be joiner on which values
										# should be joined. If it's a number, it's specific
										# valx, if it contains non-number, it's a joiner
										# element that'll join all values.
										if( $valx=~ qr/\D/o) {
											$val_joiner= $valx;

											# Done this way because, with specifying \x20, I wasn't
											# able to get \x20 back to ' ' (no amount of "$joiner" or
											# sprintf %s, $joiner seemed to convert it back.
											# XXX could be done better?
											$val_joiner= ' ' if $val_joiner eq '\s';

											$valx= undef;
										}

										$dn||= q{};
										$this->normalize( \$dn);

										my $key; # Will be initialized to cache key name (if DN!='')

										# Allow constructing the new DN from relative part
										# and ending of the current entry's DN.
										if( $dn) {
											if( my $count= $dn=~ s/\.(?=\.*$)//g) {
												$dn.= ( length $dn ? ',' : '').
													join ',', (split(',', $odn))[-$count..-1];
											}

											if( $opts{cacheref}) {
												$key= join( '|', $dn, $attr, $valx|| '');

												if( exists $opts{cacheref}{$key}) {
													pc "Using cache value for EXP '$key'";
													$comp= $opts{cacheref}{$key};
													goto EXP_DONE
												}
											}
										}

										# If DN is set, we need to load it. If not, it means
										# only one arg was given (attr name), defaulting to
										# current entry.
										if( $dn) {
											( $ret,undef,undef,$ent)= $this->load( $dn, qw/entry 1/);
											return $ret unless $ret== LDAP_SUCCESS;
										}

										my @vals= $ent->get_value( $attr);
										if( defined $valx){
											$comp= $vals[$valx];
										} else {
											$comp= join $val_joiner, @vals;
										}

										# If cacheref exists and $key is there, time for
										# us to save key to cache.
										if( $opts{cacheref} and $key) {
											pc "Rebuilding cache value for EXP '$key'";
											$opts{cacheref}{$key}= $comp
										}

										EXP_DONE:

										# XXX add this check to other ovls too?
										if( !defined $comp or !length $comp) {
											warn "ExpandVal of $attr for ".
												($dn|| 'local entry'). " is empty. ".
												"Wrong server schemas and/or schema.ldif file?\n";
										}

									# OVERLAY FIND / SUBSEARCH
									} elsif( $ovl eq 'find') { # findval
									
										# Do not operate on the attribute if this is not the
										# first level search (direct entry).
										next if $this->{level}> 0;

										if( $opts{if}) {
											my( $k, $v)= @{ $opts{if}};
											# Set up initial condition. If key begins with !,
											# it means negation, so passed== 1 instead of the
											# usual 0. Within the loop, $passed= !$passed is
											# used to always do the right thing regardless of !.
											my $passed= $k=~ s/^!//;
											my @vals= $e->get_value( $k);
											if( any { $_=~ /$v/} @vals) {
												$passed= !$passed;
											}
											if( not $passed) {
												$comp= undef;
												goto FIND_DO_CACHE
											}
										}

										my( @f, $parser);
										$parser= $this->{standard_parse};

										if( not $parser->parse( $comp)) {
											warn q{Cannot parse '}. $parser->error_input.
												q{. Reason: }. $parser->error_diag. "\n";
												return LDAP_INVALID_SYNTAX
										}

										# @f= base scope deref size time filter attrOnly attr
										@f= $parser->fields;

										if( my $count= $f[0]=~ s/\.(?=\.*$)//g) {
											$f[0].= ( length $f[0] ? ',' : '').
												join ',', (split(',', $odn))[-$count..-1];
										}

										my $key;
										if( $opts{cacheref}) {
											$key= join( '|', @f);

											if( exists $opts{cacheref}{$key}) {
												pc "Using cache value for FIND '$key'";
												$comp= $opts{cacheref}{$key};
												goto FIND_DONE
											}
										}

										# Strip valx and gvalx which are last two fields.
										# Make sure what's left are exactly 8 args for search().
										my( $gvalx, $valx)= ( 0, 0);
										if( @f== 10) { $gvalx= pop @f}
										if( @f== 9)  { $valx=  pop @f}
										if( @f!= 8)  {
											warn "Must specify 10 options for findVal overlay ".
												"(have @f).\n";
											return LDAP_INVALID_SYNTAX
										}

										# val_joiner is per-result
										my $val_joiner;
										# Support for valx to be joiner on which values
										# should be joined. If it's a number, it's specific
										# valx, if it contains non-number, it's a joiner
										# element that'll join all values.
										if( $valx=~ qr/\D/o) {
											$val_joiner= $valx;
											# Done this way because, with specifying \x20, I wasn't
											# able to get \x20 back to ' ' (no amount of "$joiner" or
											# sprintf %s, $joiner seemed to convert it back.
											$val_joiner= ' ' if $val_joiner eq '\s';

											$valx= undef;
										}

										# gval_joiner is for final value
										my $gval_joiner;
										if( $gvalx=~ qr/\D/o) {
											$gval_joiner= $gvalx;
											$gval_joiner= ' ' if $gval_joiner eq '\s';
											$gval_joiner= "\0" if $gval_joiner eq '\0';
											$gvalx= undef;
										}

										# NOTE: MUST use {} as last arg to indicate subsearch.
										my @entries= $this->search( @f, {});
										return $_ unless ( ( $_= shift @entries)== LDAP_SUCCESS);

										# Super good. So what we have now is:
										#
										# 1) We know there have been no errors
										# 2) We have entries found in @entries
										# 3) We have valx and gvalx defined
										# 4) All that's left to do is join on valx/gvalx and
										#    produce final value

										my @comp;
										$comp= q{};
										for my $ent( @entries) {
											# $f[7] is the last arg to search() -- attr to return
											my @vals= $ent->get_value( $f[7]);
											if( defined $valx){
												push @comp, $vals[$valx];
											} elsif( $val_joiner eq "\0") {
												push @comp, @vals;
											} else {
												push @comp, join $val_joiner, @vals;
											}
										}

										if( defined $gvalx){
											$comp= $comp[$gvalx];
										} elsif( $gval_joiner eq "\0") {
											$comp= \@comp;
										} else {
											$comp= join $gval_joiner, @comp;
										}

										FIND_DO_CACHE:

										# If cacheref exists and $key is there, time for
										# us to save key to cache.
										if( $opts{cacheref} and $key) {
											pc "Rebuilding cache value for FIND '$key'";
											$opts{cacheref}{$key}= $comp
										}

										FIND_DONE:

									# OVERLAY PERLEVAL
									} elsif( $ovl eq 'perl') {

										my $key;
										if( $opts{cacheref}) {
											$key= $comp;

											if( exists $opts{cacheref}{$key}) {
												pc "Using cache value for PERL '$key'";
												$comp= $opts{cacheref}{$key};
												goto PERL_DONE
											}
										}

										# XXX Eval error handling, sandbox
										$comp= eval $comp;

										# If cacheref exists and $key is there, time for
										# us to save key to cache.
										if( $opts{cacheref} and $key) {
											pc "Rebuilding cache value for PERL '$key'";
											$opts{cacheref}{$key}= $comp
										}

										PERL_DONE:
									}

								} elsif( $comp=~ /^$ovl\b/) {
									$run= 1; # Operate on the next component

									# Now extract any overlay options (i.e. exp cache 1o $ ...)
									# Make sure that we remove overlay options and leave only
									# overlay name in $comp (need to do it for the code that
									# joins the whole thing back to a value to work properly).
									# Do not skip processing if there are no options because
									# they may be defined in config file as default options.
									#next if( ( my $i= index $comp, q{ }) < 0);
									$comp=~ s/^(\w+)\s*(.*)$/$1/;
									%opts= $this->ovl_options( $ovl, $2);
								}
							}

							#
							# Here comes the part with some complicated elements. This is
							# the part of code that combines components (that were split
							# on \$ and overlay-processed) back to the processed value.
							#
							# The code is written in such a way that it remembers
							# the whitespace that was surrounding the $ ovl $ parms $ block,
							# so that the traces of the overlay can be removed, and the
							# remaining components put together, honoring the surrounding
							# whitespace exactly.
							#
							# For example, spec of "before  $ exp $ ..... $after" would be
							# processed (on 'exp' overlay's turn) into this exact value:
							# "before  VALUEafter" (notice paying attention to whitespace).
							#
							# This is done by the innermost for() block -- 
							#   for( my $i=0; $i < @comps; $i++) { ..... }
							#
							# However, this approach does not allow the overlay to create
							# new attribute values -- expansion can happen only in-place,
							# within the string. This means that you were not able to get
							# say, the list of NTP servers via 'find' overlay as an array.
							# You were only able to get it as a string, with values 
							# joined on a joiner string of choice (such as "IP1 IP2 IP3").
							#
							# It became obvious that this wasn't gonna fly without support
							# for "instantiating" new values in a 1:N manner. For example,
							# we want the following specification and result:
							#
							# value: find $ ... 2 0 500 3600 \
							#   (&(objectClass=puppetClient)(puppetClass=ntp::server)) \
							#   0 ipHostNumber \0 \0
							#
							# To produce:
							#
							# value: IP1
							# value: IP2
							# value: IP3
							#
							# Note that in a direct LDAP query, this would return multiple
							# value:s as shown. In a query through scripts/node_data though,
							# the param name ('value') would be replaced with the key name,
							# so it'd look perfectly meaningful (assuming that the Debconf
							# key is named viper/ntp_server):
							#
							# viper_ntp_server: IP1
							# viper_ntp_server: IP2
							# viper_ntp_server: IP3
							#
							# But ok anyway, to make the expansion to multiple attributes,
							# overlay first returns an arrayref instead of a scalar.
							# Then, this code right below detects there are arrayrefs in
							# the list, and expands them into multiple attribute values.
							#
							# This support for expanding into multiple attribute values
							# took me good half a day of battling to barrel through.
							#

							my $refidx= firstidx { ref} @comps; # Any comp with arrayref?
							my @compstack;

							# If we have an arrayref in the @comps list (meaning that we'll
							# be expanding to multiple attributes)
							if( $refidx>= 0) {
								# Push [@comps] onto @compstack, expanding array values (i.e.
								# arrayref with 4 values results in 4 [@comps] pushed onto
								# compstack, each with one value from the arrayref).
								for ( @{ $comps[$refidx]}) {
									push @compstack, [ @comps];
									$compstack[ $#compstack][$refidx]= $_;
								}

							# If there was no arrayref in @comps, @compstack will have just
							# one item, of course.
							} else {
								@compstack= ( [ @comps]);
							}

							# Now, for every line on compstack, load it and go into
							# processing as if that was the single line and string-only
							# expansion (it's the old code that didn't know about expanding
							# to multiple values -- we can perfectly re-use that).
							for my $tmpref( @compstack) {
								@comps= @$tmpref;

								my $skip= 0;
								# Empty current value to prepare it for putting back together
								$v= q{};

								# Put the thing back together into an attribute value, BUT
								# honoring original elements used for splitting components.
								# (NOTE: This is not a routine running at the end of all overlay
								# processing, it's a routine running at the end of each individual
								# overlay.)
								for( my $i=0; $i < @comps; $i++) {
									my $comp= $comps[$i];

									# Indicates we want to ignore the whole value, even if some
									# of its components were not undef.
									if( !defined $comp) {
										$v= undef;
										last
									}

									if( $comp eq $ovl) {
										# XXX Can be undef if value begins with some sort of
										# expansion right away. See why its happening since we
										# already do have a provision above for $1|| ''
										$v.= defined( local $_ = $splits[$i][0]) ? $_ : '';
										$skip= 2
									} elsif( $skip== 2) {
										$v.= $comp;
										$skip--
									} elsif( $skip== 1) {
										$v.= $splits[$i][1] . $comp;
										$skip--
									} else {
										if( $i> 0) {
											$v.= $splits[$i][0] . '$' . $splits[$i][1];
										}
										$v.= $comp
									}

								} # FOR $comp

								# @vstack== 1 for simple string replacement, but will contain
								# multiple values if we're expanding to multiple values.
								push @vstack, $v if defined $v;

							} # FOR my $tmpref

						} else { # IF index( $v, '$') != -1

							# IF '$' not present in entry it means there are no components
							# nor overlay processing, so directly assign $v to @vstack.
							@vstack= ( $v);
						}

						# Load all expanded values onto @v2
						push @v2, @vstack;

					} # FOR my $v

					# Finally, peddle @v2 to the attribute as its values
					$e->replace( $a, [ @v2 ]);
					last # As soon as regex matched and overlay ran, we're done with it.

				} # IF $cond matched

			} # FOR my $cond (condition)

		} # FOR my $ovl (overlay)

	} # FOR my $a (attribute)

}


#
# Helper functions below
#

# A function with a lot of built-in value. Given DN OR FILE,
# reads it in, performs all dynamic operations and returns final
# entry as either entry object or ldif.
# Error handling and everything is proper, feel free to propagate
# non-success return value back to OpenLDAP.
sub load {
	my( $this, $dn, %opts)= @_;
	%opts= (
		dnasfile => 0,
		ldif     => 0,
		entry    => 0,
		%opts,
	);
	$opts{ldif}= 1 unless $opts{entry};

	DEBUG and pd "LOAD $dn, opts: ", join( ' ', %opts);

	my( $ret, %ret);

	# Find our base entry, with possible fallbacks etc. (Note that the entry
	# is right away opened here as entry object or filehandle through %opts).
	( $ret, $dn)= $this->resolve( $dn, \%ret,
		'entry', 1, 'dnasfile', $opts{dnasfile});
	return $ret unless $ret== LDAP_SUCCESS;

	my( $entry, $fh)= @ret{qw/entry fh/};

	my $ldif= q{};

	# If open as entry, and dynamic functions are enabled, do the whole thing.
	$this->run_appender( $entry) if APPENDER;
	$this->run_overlays( $entry, $opts{origdn}); # origdn can be empty

	# If we opened as entry but need to return as ldif, convert.
	if( $opts{ldif}) {
		# Entry -> LDIF
		open my $out, '>', \$ldif;
		my $writer= new Net::LDAP::LDIF (
			$out, 'w',
			change => 0,
			raw => $RAW
		);
		if(!( $writer->write_entry( $entry))) {
			warn "Can't write_entry('$dn') to scalar\n";
			return LDAP_OPERATIONS_ERROR
		}
		$writer->done;
	}

	$ldif and $ldif=~ s/^\s*//s; # !@#$%^& LDIF write_entry outputs \n at the top!
	( LDAP_SUCCESS, $dn, $ldif, $entry)
}

# Resolve DN->file.ldif. Takes into account fallbacks and everything else.
# No dynamic operations happen (no appending or overlays).
sub resolve {
	my( $this, $obase, $oret, %opts) = @_;

	DEBUG and pd "RESOLVE '$obase', opts:", join( ' ', %opts);

	# Open entry
	my $ret= $this->dn2leaf( $obase, $oret, %opts);
	# If not there, loop over defaults
	if( $ret!= LDAP_SUCCESS) {

		# Weird to see error happen if DN was specific file...
		# some permission error on file? In that case we do report
		# an error, we don't ignore it and go for fallbacks.
		return LDAP_OTHER if $opts{dnasfile};

		for( @{ $this->{searchfallback}}) {
			my $base = $obase;
			# If substitution from config file is successful
			if( $base=~ s/$$_[0]/$$_[1]/) {
				p "RESOLVE FALLBACK TO '$base'";

				$ret= $this->dn2leaf( $base, $oret, %opts);
				last if $ret== LDAP_SUCCESS;
			}
		}
	}

	# Return what we have, either the entry was there, or it came
	# from some fallback, or if none of that worked, empty values.
	( $ret, $obase)
}

# Main function converting DNs to filesystem hierarchy. Optionally, it 
# can create missing paths, read/write/overwrite entries, return open
# file handle, etc.
# Additionally, this function was extended to accept filename in place
# of DN when option dnasfile=1. Most often, this is done when
# subtree is requested in search results, so Find routine goes reading
# in file by file, and does not need various DN resolving, but can still
# benefit from various file open functionalities built-in to dn2leaf.
sub dn2leaf {
	my( $this, $dn, $ret, %opts)= @_;
	%opts= (
		# List defaults here
		dnasfile => 0, # DN passed is a file we want to open?
		leaf     => 1, # Last element in path is entry? (if leaf=0, it's a dir)
		writeop  => 0, # Some write operation or pure read?
		overwrite=> 0, # Overwrite if exists? (Allows ADD on existing entries)
		openfh   => 0, # Open the file and return filehandle?
		entry    => 0, # Return Net::LDAP::Entry?
		verify   => 0, # Verify that fs path components exists. Ret '' if not.
		namesonly=> 0, # Return leaf name and parent dir name of an entry.
		# Add caller options to our default set
		%opts
	);

	DEBUG and pd "DN2LEAF '$dn', opts: ", join(' ', %opts);

	my( $file, $fh, $directory, $entry);

	my $key= join( '|', $dn, %opts);

	# Check if we're in cache. Excellent how we can cut right in here.
	if( $this->{cacheopen}) {
		if( exists $this->{dn2leaf_cache}{$key}) {
			pc "Using cache value for DN2LEAF '$key'";

			#( $file, $directory, $entry)= @{ $this->{dn2leaf_cache}{$key}};
			$file= ${ $this->{dn2leaf_cache}{$key}}[0];
			$directory= ${ $this->{dn2leaf_cache}{$key}}[1];
			$entry= ${ $this->{dn2leaf_cache}{$key}}[2]->clone;

			goto DN2LEAF_DONE
		}
	}

	# Preserve original value of openfh. openfh gets modified during run, but
	# we need the original setting for determining whether we can cache the
	# result (we can when openfh= 0).
	$opts{orig_openfh}= $opts{openfh};

	# Quick provision for re-using this function's code even in cases
	# where DN is a literal file we want to open and read in.
	# (Most notably in returning results from subtree traversals).
	if( $opts{dnasfile}) {
		$file= $dn;
		( $directory= $file)=~ s{/.[^/]*$}{};
		goto DN_AS_FILE
	}

	# Must be normalized by the time we reach here
	unless( $dn=~ qr/^[a-z0-9,=\/_\.-]+$/o) {
		warn "DN2LEAF Invalid or non-normalized DN '$dn'";
		return LDAP_INVALID_DN_SYNTAX
	}

	# First, split DN into filesystem path
	my @paths= reverse( split ',', $dn);
	#s{\.}{}g for @paths;# Dot is not allowed. Or well, it is, no probs.
	s{/}{.}g for @paths; # Slashes are converted to dots

	my $leaf;

	$leaf= pop @paths if $opts{leaf};

	# Important that this rewinds $currdir to the right place and does
	# the right things if we're going for any filesystem work besides reading.
	if( $opts{writeop}) {
		my $currdir= $this->{directory};
		my @i= @paths;
		while ( my $comp = shift @i) {

			$currdir .= '/'.$comp;
			my $currfile = $currdir . $this->{extension};

			if( ! -r $currfile) {
				p "DN2LEAF -r '$currfile': $!\n";
				return LDAP_NO_SUCH_OBJECT

			# We could create dir along with .ldif file on every ADD, but that would
			# leave us with empty dirs for all leaf entries. So to avoid that, we
			# create the directory only when subentries are to be placed in it.
			# The cost of this is a bit more complex elsif as follows:
			} elsif( ! -d $currdir) {
				if( @i or ( !@i and $leaf)) {
					unless( mkdir $currdir) {
						warn "dn2leaf: mkdir '$currdir': $!\n";
						return LDAP_OPERATIONS_ERROR
					}
				} elsif( @i) {
					return LDAP_NO_SUCH_OBJECT
				}
			}
		}
	}

	$directory= join( '/', $this->{directory}, @paths);

	push @paths, $leaf if $leaf;

	$file= join( '/', $this->{directory}, @paths). $this->{extension};

	if( $opts{namesonly}) {
		# If names only requested, return file and directory (subtree) name
		# of the corresponding entry.

		# If verify==0, return whatever the fs path appears to be. Otherwise,
		# return undef if file or directory is not actually there.
		if( ! -e $directory) { $directory= $opts{verify} ? undef : $directory}

		if( ! -e $file) {
			# Small consistency check -- this should never happen:
			if( defined $directory and $directory ne $this->{directory}) {
				warn "WARNING: data tree inconsistency: directory about to be used, " .
					"but file '$file' missing.\n";
			}
			$file= $opts{verify} ? undef : $file
		}

		@$ret{qw/file directory/}= ( $file, $directory);
		return LDAP_SUCCESS
	}

	DN_AS_FILE:

	$opts{openfh}= 1 if $opts{entry} or $opts{ldif};

	if( -e $file) {
		if( $opts{writeop} and !$opts{overwrite}) {
			p "DN2LEAF WON'T OVERWRITE: '$dn'\n";
			return LDAP_ALREADY_EXISTS
		} else {
			pd "DN2LEAF FOUND '$dn'"; # in file '$file'";
		}
	} else {
		if( $opts{openfh}) {
			p "DN2LEAF NOT FOUND '$dn'"; # in file '$file'";
			return LDAP_NO_SUCH_OBJECT
		}
	}

	my $open_type; # Used for printing in error message

	if( $opts{writeop}) {
		$open_type= 'wr';
		$fh= new IO::File "> $file";
		unless( defined $fh) {
			warn "Can't wropen '$file' ($!)\n";
			return LDAP_OPERATIONS_ERROR
		}
		unless( flock $fh, LOCK_EX) {
			warn "Can't flock_EX wropened '$file' ($!)\n";
			return LDAP_OPERATIONS_ERROR
		}
	}
	elsif( $opts{openfh}) {
		$open_type= 'rd';
		$fh= new IO::File "< $file";
		unless( defined $fh) {
			warn "Can't rdopen '$file' ($!)\n";
			return LDAP_OPERATIONS_ERROR
		}
		unless( flock $fh, LOCK_SH) {
			warn "Can't flock_SH rdopened '$file' ($!)\n";
			return LDAP_OPERATIONS_ERROR
		}
	}

	if( $fh and $opts{entry}) {
		my $ldif= new Net::LDAP::LDIF $fh;

		if( $ldif->error) {
			warn 'LDIF Load Error: '.$ldif->error.': '.$ldif->error_lines;

			unless( flock $fh, LOCK_UN) {
				warn "Can't flock_UN '$file' ($!)\n";
			}
			return LDAP_OPERATIONS_ERROR
		}

		$entry= $ldif->read_entry;

		unless( $entry) {
			warn "No error but also no LDIF data in '$file'; correct manually.\n";
			return LDAP_OPERATIONS_ERROR
		}

		unless( flock $fh, LOCK_UN) {
			warn "Can't flock_UN '$file' ($!)\n";
			return LDAP_OPERATIONS_ERROR
		}
		unless( $fh->close) {
			warn "Can't ${open_type}close '$file' ($!)\n";
			return LDAP_OPERATIONS_ERROR
		}
	}

	# If here, cache result. Caching enabled with cacheOpen directive
	if( $this->{cacheopen} and $entry and
	 !$opts{orig_openfh} and !$opts{writeop}) {

		pc "Rebuilding cache value for DN2LEAF '$key'";

		$this->{dn2leaf_cache}{$key}= [ $file, $directory, $entry->clone];
	}

	DN2LEAF_DONE:

	@$ret{qw/file fh directory entry/}= ( $file, $fh, $directory, $entry);

	LDAP_SUCCESS
}

# Quick debug print. p(...)
sub p { if( DEBUG) { print {*STDERR} '### ', join( ' ', @_), "\n"}}
sub pd{ if( DEBUG_DTL) { print {*STDERR} '### ', join(' ', @_), "\n"}}
sub pc{ if( DEBUG_CCH) { print {*STDERR} '+++ ', join(' ', @_), "\n"}}
sub pcd{ if( DEBUG_DTL and DEBUG_CCH){print {*STDERR} '+++ ',join(' ',@_),"\n"}}

# Subroutine that appends the entry with attributes from other entries
# according to 'entryappend' config directive. This has become a quite
# sophisticated gun.
sub run_appender {
	my( $this, $e)= @_;

	# Appender syntax can get hard to keep in mind all the time, so here's the
	# list of available ways to set it up, and the corresponding explanations:
	#
	# <attr> <value_regex> ... -> attr   <attrName>   [attrAttr]   [attrs]
	# <attr> <value_regex> ... -> append <regex_what> <regex_with> [attrs]
	#
	# Explanations:
	#
	# 0) <attr> <value_regex> is a list of attr/value pairs. All pairs must
	#    match on an entry to make it a candidate for appending.
	#
	# 1) 'attr' method: look up <attrName> attribute in each entry
	#    found. Its values are DNs which we should look up to append the
	#    original entry.
	#    Then: if there are no <attrAttr> values nor [attrs] list is given,
	#    append entry with all attributes from lookup DN.
	#    Otherwise, append only with attributes listed in [attrs] and
	#    <attrAttr> attribute.
	#
	# 2) 'append' method: similar to 1), but DN to look up is not read from 
	#    <attrName> in the entry, but is derived in-place by doing
	#    $lookup_DN= ( $entry_DN=~ s/regex_what/regex_with/).
	#    Also, similarly, either all attributes are appended, or only those
	#    listed in [attrs].

	my( $ret, %ret);

	pd "SEARCH APPENDING ". $e->dn;

	my( $id, $i, $ok, $k, $v, $r, @stack)= ( 0); # $id= 0
	for my $rule( @{ $this->{entryappend}}) {
		$id++;

		( $i, $ok, $k, $v, $r)= ( 0, 1, undef, undef, undef); # Clear vars
		$#stack= -1; # Clear stack

		# Phase 1: see if all append conditions match
		do {
			# XXX error ckin, make sure $i/$i+1 are valid
			( $k, $v)= ( $$rule[$i], $$rule[$i+1]);

			my @cond;

			if( $k eq 'dn') { @cond= $e->dn }
			else{ @cond= $e->get_value( $k) }

			my $local_ok= 0;
			for my $cond( @cond) {
				if( $cond=~ /$v/) {
					$local_ok= 1;
					last
				}
			} # FOR my $cond

			if( !$local_ok) {
				pd "SEARCH APPEND #$id skipped ($k!~ /$v/)";
				$ok= 0;
			}

		} while( $i+= 2 and $$rule[$i] ne '->');

		next if !$ok; # if this rule doesn't match, search further

		# Phase 2: now we know all conditions matched, so go on
		pd "SEARCH APPEND #$id matched '@$rule'";
		$i++; # Skip the '->' marker

		# Attrs specifically listed in cfg file are ALWAYS included from lookup
		# DN into the original entry, and are free of all suitability checks,
		# to satisfy admin who absolutely wants to add them no matter what.
		my @lookup_attrs;
		@lookup_attrs= @$rule[$i+3..$#$rule] if $$rule[$i+3];

		if( $$rule[$i] eq 'attr') {
			
			# List of DNs to lookup (usually contained in seeAlso attr.)
			my @dnattrs= $e->get_value( $$rule[$i+1]);

			# Attribute containing attrs from seeAlso to add (often 'seeAlsoAttr')
			# If no attrs found through seeAlsoAttr spec, then assume all attrs
			# from lookup DN are expected to be added (if just allowed by schema).
			my @lattrs= $e->get_value( $$rule[$i+2]);
			push @lookup_attrs, @lattrs if @lattrs;

			my $add_entry_attrs;
			$add_entry_attrs= 1 if not @lookup_attrs;

			for my $dn( @dnattrs) {

				# Allow constructing the new DN from relative part
				# and ending of the current entry's DN.
				if( my $count= $dn=~ s/\.(?=\.*$)//g) {
					$dn.= ( length $dn ? ',' : '').
						join ',', (split(',', $e->dn))[-$count..-1];
				}

				$this->normalize( \$dn);
				$ret= $this->dn2leaf( $dn, \%ret, qw/entry 1/);
				return $ret unless $ret== LDAP_SUCCESS;

				my $ae= $ret{entry};

				push @lookup_attrs, $ae->attributes if $add_entry_attrs;

				# "uniq" the array elements
				my %lookup_attrs= map { $_ => 1} @lookup_attrs;
				@lookup_attrs= keys %lookup_attrs;

				# Expand objectClasses list
				# XXX disabled for now, but I think it shouldn't be?
				#my @ocs= $e->get_value( 'objectClass');
				#my @newocs= $ae->get_value( 'objectClass');
				#for my $oc( @newocs) {
				#	if( not grep {/^$oc$/} @ocs) {
				#		$e->add( 'objectClass', $oc)
				#	}
				#}

				my @can;
				for my $oc( $e->get_value( 'objectClass')){
					# XXX this honors MUST params but really... should it,
					# in stable operation?
					push @can, $_->{name} for(
						$this->{schema}->may( $oc), $this->{schema}->must( $oc));
				}

				# XXX Optimize this loop
				for my $a( @lookup_attrs) {

					# Consider only nonexistent args for appending. XXX or if they 
					# exist but multivalue is supported. this needs to be added.
					next if $e->get_value( $a);

					# Determine if the attribute is allowed by schema, skip if not.
					if( any {/^$a$/} @can){
						pd "Entry allows append with $a";
					} else {
						pd "Entry does not allow append with $a";
						next;
					}

					# So now we know we can add it.

					my @v= $ae->get_value( $a);

					$e->add( $a, [ @v])

				} # FOR $a ( $dnattr->attrs)

			} # FOR $dn ( @dnattr)

		} elsif( $$rule[$i] eq 'append') {
			( my $dn= $e->dn)=~ s/$$rule[$i+1]/$$rule[$i+2]/;

			# XXX JOIN THE TWO LOOPS 

			# If no attrs found through seeAlsoAttr spec, then assume all attrs
			# from lookup DN are expected to be added.
			my $add_entry_attrs;
			$add_entry_attrs= 1 if not @lookup_attrs;

			$this->normalize( \$dn);
			$ret= $this->dn2leaf( $dn, \%ret, qw/entry 1/);
			return $ret unless $ret== LDAP_SUCCESS;

			my $ae= $ret{entry};

			push @lookup_attrs, $ae->attributes if $add_entry_attrs;

			# "uniq" the array elements
			my %lookup_attrs= map { $_ => 1} @lookup_attrs;
			@lookup_attrs= keys %lookup_attrs;

			# Expand objectClasses list
			# XXX disabled but should it be? (same as above)
			#my @ocs= $e->get_value( 'objectClass');
			#my @newocs= $ae->get_value( 'objectClass');
			#for my $oc( @newocs) {
			#	if( not grep {/^$oc$/} @ocs) {
			#		$e->add( 'objectClass', $oc)
			#	}
			#}

			# XXX Optimize this loop
			for my $a( @lookup_attrs) {

				# Consider only nonexistent args for appending
				next if $e->get_value( $a);

				# Determine if the attribute is allowed by schema, skip if not.
				# XXX MEMOIZE
				my @can;
				for my $oc( $e->get_value( 'objectClass')) {
					# XXX again honors ->must()
					push @can, $_->{name} for(
						$this->{schema}->may( $oc), $this->{schema}->must( $oc));
				}

				unless( any {/^$a$/} @can) {
					#p "testing for $a: YES";
				#} else {
					#p "testing for $a: NO";
					next
				}

				# So now we know we can add it.

				my @v= $ae->get_value( $a);

				$e->add( $a, [ @v])

			} # FOR my $a

		} # IF $$rule[$i] eq 'attr|append'

	} # FOR my $rule

}

# Deep comparison of arbitrary structures
sub dequal {
  my( $this, $a_ref, $b_ref) = @_;
  local $Storable::canonical = 1;
  return freeze( $a_ref) eq freeze( $b_ref)
}

# Function able to read a file and return it all, or according to $spec
# which is a specific linenumber or line matching a regex
sub read_file {
	my( $this, $directory, $file, $spec) = @_;

	unless( $directory and length $directory) {
		warn "read_file( '$file') attempted before 'directory' has been set\n";
		return LDAP_OPERATIONS_ERROR
	}

	$file=~ s{^[\./]+}{};
	$file=~ s{\.\.+}{\.}g;
	$file= join( '/', $directory, $file);

	DEBUG and p "READ FILE '$file'";

	my( $fh, @data);

	$fh= new IO::File "< $file";
	unless( defined $fh) {
		warn "Can't rdopen '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}
	unless( flock $fh, LOCK_SH) {
		warn "Can't flock_SH rdopened '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	@data= <$fh>;

	unless( flock $fh, LOCK_UN) {
		warn "Can't flock_UN rdopened '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}
	unless( $fh->close) {
		warn "Can't rdclose '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	# Spec may be a number (line number), or a regex. If it
	# is specified, the specific line number or $1 from the first
	# line matching the regex is returned. If not found, empty string
	# is returned.
	if( defined $spec and $spec =~ qr/^\d+$/o) {

		@data= ();
		@data= $data[$spec] if defined $data[$spec];
	} elsif( $spec) {
		for( @data) {
			if( /$spec/) {
				@data= ( defined $1 ? $1 : $_)
			}
		}
	}

	( LDAP_SUCCESS, @data)
}

# Function to write file on disk, taking into account proper
# steps, locking and error messages. (Writing regular files, for
# LDIF data see save() below)
sub write_file {
	my( $this, $directory, $file, $data) = @_;

	$file =~ s/^[\/\.]+//;
	$file =~ s/\.\./\./g;
	$file= join( '/', $directory, $file);

	DEBUG and p "WRITE FILE '$file'";

	my $fh= new IO::File "> $file";
	unless( defined $fh) {
		warn "Can't wropen '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}
	unless( flock $fh, LOCK_EX) {
		warn "Can't flock_EX wropened '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	unless( print {$fh} $data) {
		warn "Can't write '$file' ($!)\n";
		flock $fh, LOCK_UN; # XXX Need error ck like below?
		return LDAP_OPERATIONS_ERROR
	}

	unless( flock $fh, LOCK_UN) {
		warn "Can't flock_UN wropened '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}
	unless( $fh->close) {
		warn "Can't wrclose '$file' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	LDAP_SUCCESS
}

# Save LDIF string to given DN.
# $ldif can directly be an entry and it's then first converted to
# LDIF.
# File we save to is determined from $dn, not from dn: specified in ldif.
# XXX if data is already in ldif, does it have proper dn: when it's saved?
#   (when $dn!= ldif{dn})
sub save {
	my( $this, $dn, $ldif, %opts)= @_;

	my( $ret, %ret);

	# If we were called with an entry, turn it to LDIF.
	$ldif= $this->e2ldif( $dn, $ldif) if ref $ldif;

	# Locate/resolve the file to which we'll save data and open filehandle
	# to it. Two things can also be specified in the config file which
	# affect behavior:
	#  addoverwrites= 1/0  -- overwrite existing entry with new ADD?
	#  addignoredups= 0/1  -- if overwrite=0, do we complain or ignore the ADD?
	$ret= $this->dn2leaf( $dn, \%ret,
		qw/writeop 1/, 'overwrite', $this->{addoverwrites},
		%opts);
	if( $ret!= LDAP_SUCCESS and !$opts{modify}) {
		return LDAP_SUCCESS if
			$ret== LDAP_ALREADY_EXISTS and $this->{addignoredups};
		return $ret
	}

	# Save ldif data into file
	my $fh= $ret{fh};
	unless( print {$fh} $ldif) {
		warn "Can't print to '$ret{file}' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	# Close file
	unless( $fh->close) {
		warn "Can't wrclose '$ret{file}' ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	LDAP_SUCCESS
}

# Entry 2 LDIF
sub e2ldif {
	my( $this, $dn, $entry)= @_;

	my $ldif= q{};
	open my $out, '>', \$ldif;
	my $writer= new Net::LDAP::LDIF (
		$out, 'w',
		change => 0,
		raw => $RAW
	);
	if(!( $writer->write_entry( $entry))) {
		warn "Can't write_entry('$dn') to scalar\n";
		return LDAP_OPERATIONS_ERROR
	}
	$writer->done;

	$ldif=~ s/^\s*//s; # !@#$%^& LDIF write_entry outputs \n at the top!

	$ldif
}

# LDIF 2 entry
sub ldif2e {
	my( $this, $ldifref)= @_;

	# Turn $ldif into an entry object right away.
	open my $fh, '<', $ldifref;
	my $input= new Net::LDAP::LDIF $fh;
	my $entry= $input->read_entry;

	if( $input->error) {
		warn 'LDIF Load Error: '.$input->error.': '.$input->error_lines;
		return LDAP_OPERATIONS_ERROR
	}

	unless( $fh->close) {
		warn "Can't rdclose filehandle on scalar ($!)\n";
		return LDAP_OPERATIONS_ERROR
	}

	( LDAP_SUCCESS, $entry)
}

# Normalize. Can give scalar ref (just a DN), or a whole entry so possibly
# more than DN normalization will be done.
sub normalize {
	my( $this, $ptr)= @_;

	# Just in case we only get DN as a scalar to normalize.
	if( ref $ptr eq 'SCALAR') {
		$$ptr= lc $$ptr;
		$$ptr=~ s/\s+//g;
	} else {
		( my $dn= lc $ptr->dn)=~ s/\s+//g;
		$ptr->dn( $dn);
	}

	LDAP_SUCCESS
}

# Relocator code is Debconf/LDAP specific. It looks for 'variables' attribute
# in the Debconf entry ('variables' and debconfDBEntry is defined in
# debconf.schema so it makes sense to enable this only under the debconf tree).
# If 'variables' attrs exist, parse them to grep out viper_location=NAME (there
# should always be none or one found).
# If name matches a known relocation recipe, perform DN regex replacement
# that corresponds to this named relocation, and actually relocate it.
# The 'variables' attribute gets filled properly by using a slightly
# modified frontend on the client side which inserts those values (i.e.
# the GnomeViper frontend).
sub check_relocation {
	my ($this, $entry, $where)= @_;

	my ($ret, @variables);

	# No work if there's no 'variables' attribute
	return LDAP_SUCCESS unless @variables= $entry->get_value( 'variables');

	my $dn= $entry->dn;

	my $location_name= q{}; # Wanted relocation place

	# XXX Safety check, remove when confident it's not happening
	# We don't want two var=value definitions in the single attribute value.
	# (This does prevent multiple variables, each in its own attribute value,
	# this only checks that we do not encounter multiple = in one value).
	for( @variables) {
		if( /=.+=/) {
			warn "***** Multiple '=' found in $dn variables attribute, skipping relocation *****\n";
			return LDAP_SUCCESS
		}
	}

	# Extract location we want to relocate to and remove it from the 
	# variables list. (Implementation without removal would be more
	# elegant, but it's better to remove them).
	my @variables2;
	for( @variables) {
		if( /viper_location=(.+)/) {
			$location_name= $1
		} else {
			push @variables2, $_
		}
	}

	# No work if no viper_location= specified among variables
	return LDAP_SUCCESS unless $location_name;

	# If the location specification was found, replace variables with
	# whatever is left after taking viper_location= out of the list, and
	# relocate the entry.
	if( @variables!= @variables2) {
		if( @variables2) {
			$entry->replace( 'variables', [ @variables2]);
		} else {
			$entry->delete( 'variables');
		}

		$ret= $this->relocate( $entry, $location_name);
		return $ret unless $ret== LDAP_SUCCESS;
	}

	LDAP_SUCCESS
}

# Server-side prompter! This is a beautiful piece of code that was removed
# a while ago, and then I brought it back. Here's how it operates: when a
# Debconf entry is added to LDAP, we first make sure that both question and
# template are present, and then, THEN, we do a bit of magic on its own
# merits. We manage to open a complete, perfect Gnome Debconf frontend on
# administrator's X display of choice, where the admin can see full Debconf
# question, value input field AND another field to specify where to save
# the question (typical choices are global level, site level, host level).
# There is just one drawback to that approach-- as Debconf adds questions
# at the end of its run, it means the admin is asked the questions after
# debconf basically already does its thing and decides on answers, so the
# conditional relation between questions is lost (i.e. you don't have the
# ability to answer "NO" and then let Debconf continue as it really would
# with a "NO" answer). And there are two solutions to this problem: one,
# admin could be familiar with the package they're installing, or at least
# with the logical dependency between questions, and answer them correctly.
# Two (and better approach), use slight debconf modification on client side
# that saves the question to LDAP as soon as it is asked (this triggers 
# server prompting, and when it is done, the client re-reads the question
# to pick possibly changed value by the admin), and then debconf is aware
# of the admin's response in "real time" and can continue accordingly.
# Note that the X window is opened from the LDAP server to the admin's
# display, which is most suitable on local LANs where firewall rules or
# NAT won't make the display unreachable from the server side.
sub check_prompter {
	my ($this, $entry, $where)= @_;

	my $dn= $entry->dn;

	# Extract priority that would be used to ask the question. To have the
	# question asked, priority must be set.
	my $priority = exists $entry->{attrs}->{priority} ?
		${$entry->{attrs}->{priority}}[0] : 0;
	
	return LDAP_SUCCESS unless $priority;
	$priority||= 'low';

	my $key; # Will contain Debconf key name, if it can be found in DN

	# For each configured prompt-under location,
	while( my( $ps, $pr)= each %{$this->{addprompt}}) {

		# skip if it doesn't match the entry being ADDed
		next if $dn!~ /$ps/;

		# Figure out Debconf key name from entry DN.
		# A bit suboptimal, since it runs in a loop while it could be
		# done outside. But, doing it here ensures it runs only if the key
		# is being added under the matching place in the tree, so it doesn't
		# trigger warning on unrelated keys.
		$dn=~ /^cn=(\S+?),/;
		if( not $key= $1) {
			warn "Unable to determine Debconf key (regex '^cn=(\\S+?),') " .
				"from DN '$dn'\n";
			return LDAP_OPERATIONS_ERROR
		}

		# Great. We in game like snail in his house.

		# To be able to ask a question, we need to load the config entry
		# corresponding to the template. All 'c'-prefixed variables are 
		# config parts of the template.
		my $cdn= $dn;
		my( $ret, %ret, $centry);

		# Try and see if mapping from template to config DN succeeds.
		if( $cdn=~ s/$$pr[0]/$$pr[1]/) {
			$ret= $this->dn2leaf( $cdn, \%ret, qw/entry 1/);
		}

		if( !defined $ret) {
			warn 'Return value undefined; missing successful addPrompt '.
				'definitions in config file?\n';
			return LDAP_OPERATIONS_ERROR
		}

		# If no config entry found, even after looping over all configured 
		# template -> config regex replacements, bail out. Regularly, this
		# should not happen as Debconf saves first config then template, so
		# config should already be there. If this happens, maybe the 
		# addPromptMap did not make a correct substitution to derive the
		# config key name.
		if( $ret!= LDAP_SUCCESS) {
			p "Can't load template's corresponding config '$cdn' ($ret)";
			return $ret
		}

		# We've got the config entry.
		$centry= $ret{entry}; 

		# Do not show prompts for questions of irrelevant type (where no user
		# input is expected). But, do relocate such questions automatically to
		# site-level.
		if( $entry->{attrs}->{type}=~ /^(note|title|error)$/) {
			$this->relocate( $entry, 'Site');
			$this->relocate( $centry, 'Site');
			return LDAP_SUCCESS
		}

		# A by-the-way commentary: we manage to get Debconf running on server
		# side and not interfering with the host's regular Debconf by initializing
		# it with a custom config and Pipe driver, and feeding data about questions
		# that have to be asked via the pipe.
		# Also, this Debconf instance keeps running all the time along with
		# slapd server, it is not re-started on every question, first because
		# it would be many times slower, and second because it's not even possible
		# to do (re-initializing debconf multiple times within the same process is
		# a terrible problem).

		# Pointers from DN to template/config entry attributes, ready for loading
		# the data into Debconf Pipe cache, by reusing function for the same thing
		# in LDAP.pm
		my $et= { $dn  => $entry->{attrs}};
		my $ec= { $cdn => $centry->{attrs}};

		# Load config template and entry into Pipe's cache.
		Debconf::DbDriver::LDAP::parse_records( $dt, $et);
		Debconf::DbDriver::LDAP::parse_records( $dc, $ec);

		# Names of keys we'll check for determining if and where to relocate
		# the just-added config and template.
		# NOTE: Do not use separate fields for question/template location,
		# we used to do that but it's more annoying than really useful. To
		# enable it back, look for commented lines with comment "NO SPLIT".
		#my $tkey= 'debconf-ldap/template-location'; # NO SPLIT
		my $ckey= my $tkey= 'debconf-ldap/config-location';

		# Load previous values for later change detection.
		my $oldval=  $dm->command_get( $key);
		#my $oldtkey= $dm->command_get( $tkey); # NO SPLIT
		my $oldckey= my $oldtkey= $dm->command_get( $ckey);

		# Make sure the questions (the real question and relocation
		# questions) are always asked.
		$dm->command_fset( $key,  'seen', 'false');
		#$dm->command_fset( $tkey, 'seen', 'false'); # NO SPLIT
		$dm->command_fset( $ckey, 'seen', 'false');

		# Ask the actual question, plus subquestions where to relocate the
		# template and config entry. (On sophisticated frontends, i.e.
		# Gnome, all questions are asked in the same window due to 
		# common begin/end block, making this wonderful).
		$dm->command_beginblock;
		$dm->command_input( 'high', $key);
		$dm->command_input( 'high', $ckey);
		#$dm->command_input( 'high', $tkey); # NO SPLIT
		$dm->command_endblock;

		# Go.
		$dm->command_go;

		# New values, after answering.
		my $newval=  $dm->command_get( $key);
		my $newtkey= 'Host'; #$dm->command_get( $tkey); # NO SPLIT, XXX Site?
		my $newckey= $dm->command_get( $ckey);

		# A little beautiful hack to hide the Gnome window that stays open
		# (but unusable!) until the next question is to be asked.
		$df->win->hide;
		Gtk2->main_iteration while Gtk2->events_pending;

		# Save updated entry to the location where it was originally added.
		# (Most probably, the host level.)
		if( "$oldval" ne "$newval") { # Quotes force string comparison
			$centry->replace( value => $newval);
			$this->save( $cdn, $centry);
		}

		# Relocate if relocation requested.
		$this->relocate( $entry, $newtkey) if $newtkey ne 'Host';
		$this->relocate( $centry, $newckey) if $newckey ne 'Host';

		last # One prompter run per entry is enough, of course.

	} # WHILE my( $ps, $pr)

	# Now that the Debconf question has been asked and completely dealt
	# with, remove it from the memory cache.
	if( $key and $dt->{exists}->{$key}) {
		undef $dt->{cache}->{$key};
		$dt->{exists}->{$key}= 0;
		undef $dc->{cache}->{$key};
		$dc->{exists}->{$key}= 0;
		# XXX config option to select whether saveloc is always reinitialized
		# or set to last-state.
	}

	LDAP_SUCCESS
}

# Move entry from place to place on the filesystem.
# $loc should be one of pre-configured relocation regexes.
sub relocate {
	my( $this, $entry, $loc)= @_;

	my $dn= $entry->dn;
	my $newdn= $dn;

	$loc||= 'Site';

	# NOTE: Delete is disabled in default configurations. (To enable, add
	# "Delete" under Choices: for the template/config-location templates).
	if( $loc eq 'Delete') {
		$this->delete( $dn);
		return LDAP_SUCCESS
	}

	# If the relocation rule is defined, go through the whole cycle.
	# If not, we'll re-save the entry to its existing place.
	# (Relocation rule is not defined for location=Host (since that's
	# effectively no relocation), but we still want to re-save the
	# entry with appropriate 'variables' removed.)
	if( exists( $this->{addrelocate}->{$loc})) {
		my( $a, $b)= @{$this->{addrelocate}->{$loc}};

		unless( $newdn=~ s/$a/$b/) {
			warn sprintf("Regex for '%s' does not apply (%s =~ s/%s/%s/), skipping relocation\n", $loc, $dn, $a, $b);
			return LDAP_SUCCESS
		}
	}

	# Finally, save, and delete old entry if it was relocated.
	$entry->dn( $newdn);
	$this->save( $newdn, $entry);
	$this->delete( $dn) if $newdn ne $dn;

	LDAP_SUCCESS
}

# In the beginning, there were no overlay options supported, i.e. you
# could only specify $ exp $ .... , but to support caching etc., the need
# arose to be able to specify something like $ exp cache 10min $ ....
# Therefore, this routine should be called after overlay name is stripped,
# and it'll parse the options and do eventual adjustments on the values.
sub ovl_options {
	my( $this, $ovl, $opts)= @_;

	my @opts= split /\s+/, $opts;
	# XXX break if @opts!= even num

	unshift @opts, @{ $this->{overlayconfig}{$ovl}}
		if exists $this->{overlayconfig}{$ovl};

	unshift @opts, @{ $this->{overlayconfig}{default}}
		if exists $this->{overlayconfig}{default};
	
	my @newopts;

	# Implemented as while() and not for(i;i<@opts;i++) so that
	# we could support variable-number arguments.
	while( my $opt= shift @opts) {

		# If it's a cache time specfication, it accepts either number of
		# seconds or number of uses. Make sure time spec is converted to
		# seconds, and that the queue to place the key in is properly
		# named, and that it exists (create if not).
		if( CACHE and $opt eq 'cache') {
			my $spec= shift @opts;
			my( $n, $dur)= ( $spec=~ m/^(\d+)(\w+)?$/);

			next if not defined $n; # XXX no errmsg report here
			next if $n== 0; # Skip if person cancelled cache

			my( $qprefix, $nparm)= ( 'time', 'LIFETIME');

			goto SPEC_DONE unless $dur;
			my $unit= substr $dur, 0, 1;

			if( $unit eq 'm') {
				$n *= 60;
			} elsif( $unit eq 'h') {
				$n *= 60 * 60;
			} elsif( $unit eq 'd') {
				$n *= 24 * 60 * 60;
			} elsif( $unit eq 'w') {
				$n *= 7 * 24 * 60 * 60;
			} elsif( $unit eq 'u') {
				$qprefix= 'use';
				$nparm= 'NUM_USES';
			} elsif( $unit eq 'o') {
				$qprefix= 'op';
				$nparm= 'NUM_OPS (non-Tie)';
			}

			SPEC_DONE:
			# Now that cache spec has been parsed, based on it we need to determine
			# the queue that will cache the object (need to do it because
			# Memoize::Expire cache rules are per hash, not per key, so we need
			# separate hash for each cache option).
			# Note also that queues are per-overlay and per-spec, not just per-spec,
			# so it's not possible that overlays confuse their cached values.

			pcd "Parsed cache spec '$spec' to '$nparm $n' ".
				"(queue $qprefix, ovl $ovl)";

			# Create queue if it doesn't exist yet.
			if( not defined $this->{ovl_cache}{$qprefix}{$ovl}{$n}) {
				if( $qprefix ne 'op') {
					# Time and use queues are tied, operation count queue is not
					tie %{ $this->{ovl_cache}{$qprefix}{$ovl}{$n}} =>
						'Memoize::Expire', $nparm => $n;
				} else {
					# This is op-qeueue, realized without Tie.
					%{ $this->{ovl_cache}{$qprefix}{$ovl}{$n}}= ();

					# Register initial and current (same as initial) validity period.
					$this->{op_cache_valid}{$ovl}{$n}= $n;
				}

				p "Created cache queue $qprefix-$ovl-$n ($nparm $n)";
			}

			# Onto @newopts, add cacheref which is a direct pointer to the queue
			# in question that the caller can query to see if the cached value
			# is in there.
			# We unshift here so that any manual specs in the entry always
			# would override our values dereived here. The override will elegantly
			# happen when @newopts is turned to a hash on the receiver end,
			# i.e. %opts= $this->ovl_options( $optspec).
			unshift @newopts, 'cacheref', $this->{ovl_cache}{$qprefix}{$ovl}{$n};

			# Push could be done outside of per-option block, but the way we do it
			# here, we can achieve the option to be ignored if the top if() doesn't
			# match (if say, caching is disabled with CACHE => 0 constant).
			# XXX Note that we push original $spec here, not the processed one,
			# even if we did process it to extract expiry time etc. It's left
			# to see what is more useful.
			push @newopts, $opt, $spec;

		# If it's prefix= (file prefix), remove any [./]+ at the beginning
		# of file spec.
		} elsif( $opt eq 'prefix') {
			my $val= shift @opts;
			$val=~ s{^[\./]+}{};
			$val=~ s{\.\.+}{\.}g;
			push @newopts, $opt, $val;

		# Conditional
		} elsif( $opt eq 'if') {
			push @newopts, $opt, [ (shift @opts), (shift @opts)];

		} else {
			# Default action -- just pass option on
			push @newopts, $opt, (shift @opts)
		}
	}

	@newopts
}

# This function became necessary when it became possible for direct-entry
# functions (sub search, sub modify etc.) to result in calling each other
# iteratively (we needed to control looping depth), and later, it was also
# necessary for the functions to know if they're direct entry or not, so that
# they can clean or keep per-operation cache.
sub check_state {
	my( $this, $arg)= @_;

	# hashref as last arg identifies we're re-invoking search from backend,
	# that is, it's not a direct call from slapd.
	# We keep track of how many loops we've done via $this->{level}.
	if( ref $$arg[@$arg-1]) {
		pop @$arg;
		$this->{level}++;

	# If here, means we are entering a new search from slapd
	} else{
		$this->{level}= 0;

		$this->{dn2leaf_cache}= undef; # Clear per-op dn2leaf cache

		while( my ($ovl, $ovlref)= each %{ $this->{op_cache_valid}}) {
			for my $n( keys %{ $ovlref}) {
				if( --$ovlref->{$n}< 1) {
					$this->{ovl_cache}{op}{$ovl}{$n}= undef;
					$ovlref->{$n}= $n;
				}
			}
		}
	}

	$this->{start}[ $this->{level}]= time;
}

#
# Debconf stuff for server-side prompting
#

# Debconf initializer function. Initially, the idea was to (re)initialize
# debconf on every run, but as things progressed and the overall design
# improved, it became possible to initialize debconf just once and keep it
# running. (Which is great, because re-initializing debconf without exiting
# the program does not work for the most part anyway ;-)
sub debconf_initialize {
	my( $this)= @_;

	# Set up minimal valid debconf state (in the end, it'll contain
	# the fixed contents below + the template/config of the question
	# it gets to ask).
	$cin= qq{
Name: debconf/frontend
Template: debconf/frontend
Value: Gnome
Owners: debconf
Flags: seen

Name: debconf-ldap/template-location
Template: debconf-ldap/template-location
Value: Site
Owners: debconf-ldap
Flags: seen

Name: debconf-ldap/config-location
Template: debconf-ldap/config-location
Value: Site
Owners: debconf-ldap
Flags: seen
};

	$tin= qq{
Name: debconf/frontend
Choices: Dialog, Readline, Gnome, Kde, Editor, Noninteractive
Default: Dialog
Description: Interface to use:
Extended_description: Packages that use debconf for configuration share a common look and feel. You can select the type of user interface they use.\n\nThe dialog frontend is a full-screen, character based interface, while the readline frontend uses a more traditional plain text interface, and both the gnome and kde frontends are modern X interfaces, fitting the respective desktops (but may be used in any X environment). The editor frontend lets you configure things using your favorite text editor. The noninteractive frontend never asks you any questions.
Type: select
Owners: debconf/frontend

Name: debconf-ldap/template-location
Type: select
Choices: Host, Site, Global
Default: Site
Description: Specify template save location:

Name: debconf-ldap/config-location
Type: select
Choices: Host, Site, Global
Default: Site
Description: Specify value save location:
};

	# Automagically works due to /etc/debconf.conf.pipe (needed as part
	# of the setup).
	{ no warnings 'once';
		open CIN,  '<', \$cin;
		open COUT, '>', \$cout;
		open TIN,  '<', \$tin;
		open TOUT, '>', \$tout;
	}

	# Okay, power it up
	Debconf::Db->load;

	$dc = Debconf::DbDriver->driver( Debconf::Config->config);
	$dt = Debconf::DbDriver->driver( Debconf::Config->templates);

	$df= Debconf::AutoSelect::make_frontend();

	$dm= Debconf::AutoSelect::make_confmodule();

	LDAP_SUCCESS
}


#
# Yet to be ported over and coded properly
#

sub compare {
    print {*STDERR} "Here in compare, @_\n";
    my $this= shift;
    my( $dn, $avaStr)= @_;
    my $rc= 5;    # LDAP_COMPARE_FALSE

    $avaStr =~ s/=/: /m;

    if( $this->{$dn} =~ /$avaStr/im) {
        $rc= 6;    # LDAP_COMPARE_TRUE
    }

    return $rc;
}

sub modrdn {
    print {*STDERR} "Here in modrdn, @_\n";
    my $this= shift;

    my( $dn, $newdn, $delFlag)= @_;

    $this->{$newdn}= $this->{$dn};

    if( $delFlag) {
        delete $this->{$dn};
    }
    return 0;
}

1

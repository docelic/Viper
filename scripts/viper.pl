#!/usr/bin/perl
#
# Script showing how to run Viper as a standalone program, separate
# from slapd. Usage in this way is suitable if you want to read directory
# data completely circumventing slapd but still getting the exact same
# results and code paths.
#
# Most notable use is running your search query of choice under Perl
# profiler, such as:
#
#  perl -d:DProf     scripts/standalone.pl; dprofpp
#  perl -d:SmallProf scripts/standalone.pl; ./scripts/sprofpp
#
# The script contains some hardcoded values, reflecting the specific
# issue that was being profiled. There are no command line switches or
# options, to make the script suit your purposes you will most probably
# want to edit the source.
#
# To produce the exact same behavior as when running from slapd, Viper
# has to be initialized with the same config. The easiest way to do
# that is to run Viper once, using slapd, and use 'savedump' directive
# at the end of the suffix config. That'll produce a Storable dump of
# current config.
# Then, here, instead of sending a bunch of ->config() lines, you can
# just invoke ->loaddump( FILENAME).
#
# In case you can't use that approach, you need to feed in the config
# using ->config(), of course.
#
#
# SPINLOCK - Advanced GNU/Linux networks in commercial and education sectors
#
# Copyright 2008-2009 SPINLOCK d.o.o., http://www.spinlocksolutions.com/
#                     Davor Ocelic, docelic@spinlocksolutions.com
#
# http://www.spinlocksolutions.com/
# http://techpubs.spinlocksolutions.com/
#
# Released under GPL v3 or later.
#

use warnings;
use strict;

use Viper;

package Viper;

my $obj= Viper->new;
p $obj;

# Set base directory so that loaddump can operate
$obj->config( 'directory', '/var/lib/ldap/viper');

# Load Storable dump of complete config
$obj->config( 'loaddump',  'ou=clients.dump');
p $obj;

# Must invoke to re-initialize object pointers
# within config (they don't survive Storable dump/restore, of course).
$obj->init;

# Perform a search
my @res= $obj->search( 'ou=hosts,o=c1,ou=clients', 2, 0, 500, 3600,
	"(&(objectClass=puppetClient)(puppetClass=ntp::server))",
	0);

# Show results
p @res;


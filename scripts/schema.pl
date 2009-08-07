#!/usr/bin/perl
#
# SPINLOCK - Advanced GNU/Linux networks in commercial and education sectors.
#
# Copyright 2008-2009 SPINLOCK d.o.o., http://www.spinlocksolutions.com/
#                     Davor Ocelic, docelic@spinlocksolutions.com
#
# http://www.spinlocksolutions.com/
# http://techpubs.spinlocksolutions.com/
#
# Released under GPL v3 or later.
#
#
# Tool to retrieve schema from server in LDIF format.
# Needed so that it can be loaded into Viper, so that Viper becomes
# aware of server's schema through schemaLDIF config option.
#
# This is just a basic script that assumes unauthenticated schema
# retrieve will work.
#
# perl schema.pl <ldap-srv>
#
# Example:
#
# sudo sh -c 'perl scripts/schema.pl  > configs/schema.ldif'

use warnings;
use strict;

use Net::LDAP qw//;
use Net::LDAP::Schema qw//;

my $server= $ARGV[0] || 'localhost';

my $ldap = Net::LDAP->new ( $server );
$ldap->bind or die "Can't bind\n";

my $schema = $ldap->schema or die "Can't get schema\n";
$schema->dump;


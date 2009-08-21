#!/usr/bin/perl
#
# Retrieve key from LDAP and print to STDOUT.
# Simple script with little value, besides for testing. Also, if a
# value is base64-encoded and is not readable offhand with ldapsearch,
# with this tool it will be, because ($entry->dump decodes it before display).
#
# Usage: perl scripts/get-key.pl FULL-DN
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

use Net::LDAP;

$ldap = Net::LDAP->new( 'localhost') or die "$@\n";

$mesg = $ldap->bind ;    # an anonymous bind

$mesg = $ldap->search( # perform a search
		base   => $ARGV[0] ||
			"cn=netcfg/get_hostname,cn=h2,ou=hosts,o=c1.com,ou=clients",
		filter => '(objectclass=debconfDbEntry)',
		scope => 'base',
		);

$mesg->code and die $mesg->error;

foreach $entry ($mesg->entries) { $entry->dump }


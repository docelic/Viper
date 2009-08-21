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
# Script reads in LDIF file and briefly prints contained DNs.
# Very simple script, used for detecting any syntactical errors
# in LDIFs.
#
# read-ldif <ldif-file>
#
# Optionally, entry dump can be displayed if invoked appropriately.
#
# read-ldif <ldif-file> verbose

use Net::LDAP::LDIF;
use Data::Dumper;

$ldif = Net::LDAP::LDIF->new(
	$ARGV[0], "r",
	onerror => 'undef', # warn, die
	);

$verbose= $ARGV[1];

while( not $ldif->eof ( ) ) {
	$entry = $ldif->read_entry ( );

	if ( $ldif->error ( ) ) {
		print "Error msg: ", $ldif->error ( ), "\n";
		print "Error lines:\n", $ldif->error_lines ( ), "\n";
	} else {

		print $entry. ' | '. $entry->dn. "\n";
		print Dumper \$entry if $verbose;
	}
}
$ldif->done;


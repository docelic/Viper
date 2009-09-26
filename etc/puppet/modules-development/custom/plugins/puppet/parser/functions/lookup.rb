#!/usr/bin/env ruby
#
# External lookup script that queries LDAP.
#
# Usage:
#
#           TYPE    ITEM        DEFAULT(=ITEM)
#   lookup('file', 'ntp.conf', '/etc/ntp.conf')
#   lookup('file', '/etc/ntp.conf')
#
# Based on concept of external lookup from
#   http://www.devco.net/archives/2009/08/31/complex_data_and_puppet.php
#
# For easier use, a couple often-used "aliases" are also defined:
#
#  f(...) == lookup("file", ...)
#  p(...) == lookup("package", ...)
#  s(...) == lookup("service", ...)
#

require 'ldap'

module Puppet::Parser::Functions

	newfunction(:lookup, :type => :rvalue) do |args|
		client= lookupvar 'clientName'
		type, name, default= *args
		default||= name

		begin
			c= LDAP::Conn.new 'localhost', 389
			c.set_option LDAP::LDAP_OPT_PROTOCOL_VERSION, 3
			c.bind
		rescue Exception => e
			c.perror
			return
		end

		key= "cn=#{name},ou=#{type}s,ou=resolver,o=#{client},ou=clients"

		begin
			c.search(key, LDAP::LDAP_SCOPE_BASE, "(objectclass=*)") { |e|
				# XXX not the real attribute we want to see
				return e.vals 'cn'
			}
		rescue LDAP::ResultError => msg
			# Ignore NO_SUCH_OBJECT errors as we use a default then
			c.perror if c.err!= LDAP::LDAP_NO_SUCH_OBJECT
		end

		default
	end

end

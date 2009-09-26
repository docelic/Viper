#!/usr/bin/env ruby
#
# External lookup script that queries LDAP.
#
# Usage possible from command line or Puppet.
#
# Cmdline: ruby lookup.rb CLIENT TYPE KEY           DEFAULT(=KEY if empty)
# Such as: ruby lookup.rb c1.com file ntp.conf      /etc/ntp.conf
#      Or: ruby lookup.rb c1.com file /etc/ntp.conf
#
#  Puppet: lookup('file', 'ntp.conf', '/etc/ntp.conf')
#      Or: lookup('file', '/etc/ntp.conf')
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

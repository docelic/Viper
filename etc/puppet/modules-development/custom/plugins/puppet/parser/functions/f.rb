require 'ldap'

module Puppet::Parser::Functions

	newfunction(:f, :type => :rvalue) do |args|
		function_lookup 'file', *args
	end

end

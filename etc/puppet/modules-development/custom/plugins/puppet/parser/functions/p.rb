require 'ldap'

module Puppet::Parser::Functions

	newfunction(:p, :type => :rvalue) do |args|
		function_lookup 'package', *args
	end

end

module Puppet::Parser::Functions

	newfunction(:s, :type => :rvalue) do |args|
		function_lookup 'service', *args
	end

end

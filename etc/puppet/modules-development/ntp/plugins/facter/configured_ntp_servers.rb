# This fact returns the set of configured NTP servers
# from the managed config files.
# Source: http://git.black.co.at/?p=module-ntp;a=blob;f=plugins/facter/configured_ntp_servers.rb

Facter.add("configured_ntp_servers") do
	setcode do
		Dir.glob("/etc/ntp*.conf").collect do |name|
			File.new(name).readlines.collect do |line|
				matches = line.match(/^(server|peer) ([^ ]+) /)
				if matches.nil?
					nil
				else
					matches[2]
				end
			end
		end.flatten.uniq.compact.sort.join(" ")
	end
end


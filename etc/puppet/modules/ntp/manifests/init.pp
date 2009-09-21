class ntp {

	class server {
		include ntp::config
		include ntp::package
	}
	class client {
		include ntp::config
		include ntp::package
	}

	class server::stock {
		include ntp::package
	}
	class client::stock {
		include ntp::package
	}


	class config {
		file {
			"/etc/ntp.conf":
				ensure => present,
				mode => 0644,
				owner => root,
				group => root,
				content => template('ntp/ntp.conf.erb'),
				before => Package['ntp'],
		}
	}

	class package {
		package {
			"ntp":
				ensure => latest,
		}
	}
}

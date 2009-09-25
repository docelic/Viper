class ntp {

	class config {
		file { "ntp.conf":
				name    => $operatingsystem ? {
					default => "/etc/ntp.conf",
				},
				ensure  => present,
				mode    => 0644,
				owner   => root,
				group   => root,
				content => template('ntp/ntp.conf.erb'),
				before  => Package['ntp'],
		}
	}

	class package {
		package { "ntp":
				name    => $operatingsystem ? {
					default => "ntp",
				},
				ensure => latest,
		}
	}

}

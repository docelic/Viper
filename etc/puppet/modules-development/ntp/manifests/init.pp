class ntp {

	class config {
		file { "ntp.conf":
				name    => $operatingsystem ? {
					default => "/etc/ntp.conf",
				},
				ensure  => file,
				mode    => 0644,
				owner   => root,
				group   => root,
				content => template('ntp/ntp.conf.erb'),
				before  => Package['ntp'],
		}

		class disabled {
			file { "ntp.conf":
				ensure => absent,
			}
		}
	}

	class package {
		package { "ntp":
				name    => $operatingsystem ? {
					default => "ntp",
				},
				ensure => latest,
		}

		class disabled {
			package { "ntp":
				ensure => purged,
			}
		}
	}

	service { "ntp":
		name    => $operatingsystem ? {
			default => "ntp",
		},
		subscribe => File["ntp.conf"],
	}

}

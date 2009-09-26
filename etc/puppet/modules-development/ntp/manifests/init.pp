class ntp {

	class config {

		$ntp_conf = lookup("file", "/etc/ntp.conf")

		file { $ntp_conf:
				ensure  => file,
				mode    => 0644,
				owner   => root,
				group   => root,
				content => template('ntp/ntp.conf.erb'),
				before  => Package['ntp'],
		}

		class disabled {
			file { $ntp_conf:
				ensure => absent,
			}
		}
	}

	class package {

		$ntp = lookup("package", "ntp")

		package { $ntp:
				ensure => latest,
		}

		class disabled {
			package { $ntp:
				ensure => purged,
			}
		}
	}

}

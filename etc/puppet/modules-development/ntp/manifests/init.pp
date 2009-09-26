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
			$ntp_conf = lookup("file", "/etc/ntp.conf")

			file { $ntp_conf:
				ensure => absent,
			}
		}
	}

	class package {
		$ntp = lookup("package", "/etc/ntp.conf")

		package { $ntp:
				ensure => latest,
		}

		class disabled {
			$ntp = lookup("package", "/etc/ntp.conf")

			package { $ntp:
				ensure => purged,
			}
		}
	}

}

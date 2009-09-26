class ntp {

	class config {
		$ntp_conf = f("/etc/ntp.conf")
		$ntp = p("ntp")

		file { $ntp_conf:
				ensure  => file,
				mode    => 0644,
				owner   => root,
				group   => root,
				content => template('ntp/ntp.conf.erb'),
				before  => Package[$ntp],
		}

		class disabled {
			$ntp_conf = f("/etc/ntp.conf")

			file { $ntp_conf:
				ensure => absent,
			}
		}
	}

	class package {
		$ntp = p("ntp")

		package { $ntp:
				ensure => latest,
		}

		class disabled {
			$ntp = p("ntp")

			package { $ntp:
				ensure => purged,
			}
		}
	}

}

class bind9 {

	class config {
#		$bind_dir = f("/etc/bind")
#
#		file { $bind_conf:
#				ensure  => file,
#				mode    => 0644,
#				owner   => root,
#				group   => root,
#				content => template('bind/bind.conf.erb'),
#				before  => Package[$bind],
		}

		class disabled {
			$bind_dir = f("/etc/bind")

			file { $bind_dir:
				ensure => absent,
			}
		}
	}

	class package {
		$bind= [ p("bind9"), p("bind9-host"), p("bind9utils") ]

		package { $bind:
				ensure => latest,
		}

		class disabled {
			$bind= [ p("bind9"), p("bind9-host"), p("bind9utils") ]

			package { $bind:
				ensure => purged,
			}
		}
	}

}

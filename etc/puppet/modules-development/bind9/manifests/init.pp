class bind9 {

	class config {
		$bind9_conf = lookup("file", "/etc/bind/named.conf.local")
		$bind9_opts = lookup("file", "/etc/bind/named.conf.options")

		file {
			$bind9_conf:
				ensure  => file,
				mode    => 0644,
				owner   => root,
				group   => bind,
				content => template('bind9/named.conf.local.erb'),
				before  => Package[$bind9];
			$bind9_opts:
				ensure  => file,
				mode    => 0644,
				owner   => root,
				group   => bind,
				content => template('bind9/named.conf.options.erb'),
				before  => Package[$bind9];
		}

		class disabled {
			$bind9_dir = lookup("file", "/etc/bind/")

			file { $bind9_dir:
				ensure => absent,
			}
		}
	}

	class package {
		$bind9 = [
			lookup("package", "bind9"),
			lookup("package", "bind9-host"),
			lookup("package", "bind9utils")
		]

		package { $bind9:
				ensure => latest,
		}

		class disabled {
			$bind9 = [
				lookup("package", "bind9"),
				lookup("package", "bind9-host"),
				lookup("package", "bind9utils")
			]

			package { $bind9:
				ensure => purged,
			}
		}
	}

}

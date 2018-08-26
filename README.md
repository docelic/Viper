# Viper

Viper is a system for fully automated installation, configuration and monitoring of Debian GNU based systems. The development started in 2008.

Viper uses a modern approach (debian-installer during installation, configuration management tool later, etc.), works with existing Debian packages, and does not require any custom patching of either install media, client, or server.

The basis of the whole system is an OpenLDAP server with a custom Viper backend with radically new and dynamic functionality, and holding all configuration data.

## Introduction

LDAP has the potential to be enormously successful in configuration management, but its flat data structure, absence of any kind of dynamic behavior, and heaps of duplicated data typically make it an inefficent tool for smaller teams.

Using LDAP for complex configuration management in a seamless, successful, non-intrusive way has been reserved for high-end customers who have invested significant resources into making it work as desired in their environments.

Viper was developed to build on LDAP's great strengths while solving many of its typical deficiencies when it comes to configuration management.

As part of Viper, a custom OpenLDAP backend has been implemented. This backend should be used specifically for configuration management and not other generic data.

Finally, everything has been commented, with the availability of complete, working config files and this guide.

Viper is released under GNU GPL v3 or later.

## Features Overview

Here follows a summarized list of Viper's key features, especially those that may differ from traditional config management or LDAP principles. (The explanations on how or why Viper does what it does can be found in other sections below; this section focuses only the high-level summary of user functionality.)

Viper uses on Debconf, OpenLDAP, ISC DHCP, and a software configuration management tool (such as Puppet) for the complete setup.

One Viper server instance can store and serve data for multiple separate customers, with multiple separate machines each.

Viper "rewrites" incoming LDAP searches in numerous ways, completely avoiding duplication of data, while at the same time transparently handling all clients who issue their standard LDAP queries and expect to find information in their standard locations.

With the help of a CGI script, Viper also handles clients who don't use LDAP searches but request data over HTTP, such as clients requesting preseed data at the beginning of machine installation.

After the machine has been initially installed, machines' Debconf settings (as well as config management software's settings) are configured to use LDAP and query the Viper server for information.

All Viper's configuration-related key=value pairs are stored in Debconf-conformant LDAP schema (objectClass = `debconfDbEntry`). This makes it possible to treat all keys equally, regardless of whether they are part of the mandatory preseed contents, or non-essential Debconf questions, or custom additional configuration data added by site administrators.

The usual (non-Viper) way for system administrators to preseed Debconf in advance is to extract the packages' Debconf question templates, answer them, and save them to the Debconf database, so that the questions and answers are already there when the clients ask for them. However, extracting and answering Debconf questions ahead of time is quite a nuisance, especially when the packages or questions needed are not known in advance or there are many dependencies to handle as well.

Viper makes it possible to answer all known/existing questions automatically as usual, while all new/unseen questions are either shown interactively at the machine being installed, or they can open a Debconf popup window on the administrator's remote host of choice. This way, new questions can be answered from a central location regardless of where on the network a package is being installed, and then the answers can be saved to Debconf as expected for all future queries.

Furthermore, for every Debconf question that is asked (locally or remotely), an additional follow-up question is presented to the administrator, allowing him to insert the answer in LDAP at the individual machine level (applying only to that machine), at the customer level (applying to all customer's machines), or at the global level (applying to all machines of all customers).

## Server Choice Considerations

Viper ships with the mentioned custom backend for OpenLDAP and it must be installed for Viper to work. This backend is the primary component of Viper and it implements numerous features that make Viper an extremely powerful tool for configuration management.

Please note that Viper's OpenLDAP backend is implemented in Perl and it depends on OpenLDAP's `slapd-perl`, which is subject to a couple important notes:

1. OpenLDAP's `slapd-perl` never had a particularly full-featured implementation, and it must be enabled with a config option during OpenLDAP build
1. While Viper's backend is a full-fledged piece of software, it is bound by limitations of `slapd-perl`
1. The two primary limitations of `slapd-perl` are 1) very modest access controls, and 2) incomplete API which makes most of slapd's data not directly accessible to Perl (thus requiring some duplication of configuration)

Given's Viper very specific and contextualized purpose, for maximum convenience the default Viper config files also reinstate the old and simple `slapd.conf` style of configuration instead of the new (and much more complex) `cn=config` style.

And finally, necessary to mention here is that, by default, the install clients will ask for preseed data over unencrypted HTTP connections.

Therefore, all things considered, we advise to only run Viper servers on dedicated machines and inside local/trusted networks, unless you first read this guide in entirety and possibly send us patches to make Viper "thougher" and suitable for other environments.

## First Steps

The easiest way to start with Viper is to clone the files from Git and place them in `/etc/ldap/viper/`:

```
mkdir -p /etc/ldap
cd /etc/ldap
git clone git://github.com/crystallabs/Viper.git viper
cd viper
```

## Net::LDAP::FilterMatch.pm Fix

In Perl module Net::LDAP prior to version 0.4001 (2010 and earlier) there was a [bug in FilterMatch escaping](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=540938).
If you happen to be using one of those older versions, please upgrade or manually apply patch [support/FilterMatch.pm.patch](https://github.com/crystallabs/Viper/blob/master/support/FilterMatch.pm.patch).

## Installation Procedure

There is a simple shell script [scripts/viper-setup.sh](https://github.com/crystallabs/Viper/blob/master/scripts/viper-setup.sh) delivered with Viper which contains the list of steps to be performed on a server machine to install Viper. After a mandatory manual review you could run this script to perform the installation. The script is idempotent; running it multiple times will result in no adverse effects, so in case anything fails, you can resolve the conditions and then run the script again.

*Please note that the script will, by default, overwrite your existing slapd, dhcpd, and puppet config files.*

In summary, to perform the installation, you will:

1. Find a suitable Devuan GNU+Linux, Debian GNU, or Ubuntu machine to use as Viper install server
1. Note the machine's hostname
1. Find name of the network interface on which Viper's DHCP server will be listening
1. Install required packages: `apt install slapd ldap-utils libfile-find-rule-perl libnet-ldap-perl libtext-csv-xs-perl liblist-moreutils-perl isc-dhcp-server-ldap make sudo libyaml-perl apache2`
1. Configure a network interface or an alias to listen on IP 10.0.1.1/24 for one client. This must be done to load test data and have DHCP server start properly: `ifconfig eth0:1 inet 10.0.1.1 netmask 255.255.255.0`
1. Verify and run script `scripts/viper-setup.sh`, or manually execute lines from it
1. Make final adjustments to config files if necessary
1. Restart OpenLDAP
1. Review and/or modify LDIF data and load it into the server
1. Restart ISC DHCP
1. Run a couple tests to verify successful installation

More detailed descriptions of some of these steps follow:

### Machine and Ethernet Interface Name

If you don't specify ethernet interface name, the default will be `sharedNetwork`.

If you don't specify server host name, the default will be `viper`.

### Required Package Installations

The packages needed to run Viper have been listed above.

The HTTP server is included in the list because Viper uses a simple CGI script to provide preseed data via HTTP for client machines during installation (queried automatically from debian-installer). Our example uses Apache, even though any web server that can execute CGI will do well.

When installing OpenLDAP, answer "Yes" to the debconf question "Omit OpenLDAP server configuration?", because the complete config file will come supplied from Viper, and you can further tune it from there if desired.

It is known and expected that OpenLDAP and DHCP servers will not start cleanly during the `apt install` step, due to incomplete configuration. The appropriate config files for both services will be installed later from Viper's templates.

### Viper's Etc Config Files

Viper does not intend to unconditionally or inflexibly replace your services' config files with its own. You can just as easily manually modify any of your existing services' config files to insert parts of configurations needed by Viper.

However, it is generally assumed that you will dedicate a physical or virtual machine to the Viper server, and in that context, Viper's default config files can easily replace the services' ones. That will provide you with a known-good setup on which you can run the test suite and to which you can add your own configuration. 

`viper-setup.sh` will copy all the required files from `$VIPER_ROOT/etc/` (which is usually `/etc/ldap/viper/etc`) into the system's `/etc/` and overwrite any existing files.
Currently, this includes config files for OpenLDAP, ISC DHCP, and Puppet.

### Viper LDIFs

`viper-setup.sh` will also load the necessary bootstrap LDIFs into LDAP as part of the installation procedure. It will do that by invoking `make` in the directory `ldifs/`.

The only LDIF file that should be modified in case you will be loading the LDIFs manually is `ldifs/1-dhcp.ldif`, containing the server machine's hostname and network interface to listen on. If you have ran the script with the corresponding eth name and hostname parameters, the script has done the replacements for you.

The LDIF contents are supposed to load into the custom Viper backend for OpenLDAP, which comes pre-configured in Viper's OpenLDAP config files.
Therefore, be sure to restart OpenLDAP with the new configuration before loading the LDIFs.

LDIFs are loaded by simply running `make` in the directory `ldifs/`. The Makefile, in turn, runs `sh add`, which finds all `*.ldif` files in the directory and loads them using `ldapadd` and the preconfigured bind credentials.

Once LDIFs are loaded, please restart the ISC DHCP server.

### Preseed CGI Script

Viper ships with `scripts/preseed`, a CGI script used for providing preseed data to Debian-based clients. The preseed format is natively supported by Debian installer, requiring no modifications on the client. On incoming requests, the script runs and uses the client's IP address to search for matching `dhcpHWAddress` and `ipHostNumber` in the LDAP directory. Then it compiles the preseed file contents and delivers them back to the client.

For maximum convenience and manual testing, the preseed data for a client can also be obtained by accessing the CGI script with query parameter `host=HOSTNAME`, and additionally with `client=DOM.AIN` if the LDAP search for hostname alone would find more than one result.

During our testing, it was determined that preseeding the clients during installation with all existing Debconf answers (instead of only those required by the installation) leads to unusual problems. Therefore, the preseed CGI script only returns the Debconf entries marked for inclusion in preseeds, but all keys can be requested with a query parameter `flag=` or alternatively `debug=1`.

## Testing the Installation

The installation procedure hopefully finished without giving any errors, and the LDIFs were loaded.

At this point, to just do a quick and immediate test, run `ldapsearch -x`. If this prints various LDAP entries to screen, you have a working server installation.

Some default data is included with the installation. That includes a "customer" with name "c1.com", and three hosts, h1, h2 and h3.

Altogether, you can run the following additional ldapsearches for more testing:

```
ldapsearch -x -b ou=dhcp
ldapsearch -x -b ou=defaults
ldapsearch -x -b ou=clients
```

### Testing with ldapsearch

Ldapsearch query for `cn=h2,ou=hosts,o=c1.com,ou=clients` is a pretty good way of determining if everything is working alright. Here's how the output from the command should look like. The exact attribute values are not important, it is just important that there are no unprocessed values in the output. That is, nothing with '$' and nothing with only half-populated information.

```
$ ldapsearch -x -b cn=h2,ou=hosts,o=c1.com,ou=clients

# extended LDIF
#
# LDAPv3
# base  with scope subtree
# filter: (objectclass=*)
# requesting: ALL
#

# h2, hosts, c1.com, clients
dn: cn=h2,ou=hosts,o=c1.com,ou=clients
objectClass: top
objectClass: device
objectClass: dhcpHost
objectClass: ipHost
objectClass: ieee802Device
objectClass: puppetClient
cn: h2
ipHostNumber: 10.0.1.8
macAddress: 00:11:6b:34:ae:89
puppetclass: test
puppetclass: ntp::server
hostName: h2
ipNetmaskNumber: 255.255.255.0
clientName: c1.com
ipNetworkNumber: 10.0.1.0
ipBroadcastNumber: 10.0.1.255
domainName: c1.com

# search result
search: 2
result: 0 Success

# numResponses: 2
# numEntries: 1
```

### Testing with scripts/node_data

```
perl scripts/node_data h2.c1.com
```

### Testing with scripts/preseed

```
QUERY_STRING=ip=10.0.1.8 perl scripts/preseed
```

### Testing with HTTP client

```
wget http://10.0.1.1/cgi-bin/preseed.cfg?ip=10.0.1.8 -O /tmp/preseed.cfg
```

## Troubleshooting

The following two things should be done as a pre-requirement for any quick troubleshooting:

1. Tune the desired internal debug options in Viper. This is done in `/etc/ldap/viper/Viper.pm` (search for "DEBUG")

1. Run `slapd` in foreground and watch its logs. We run with slapd debug
level 0 because most of the time we are interested in seeing Viper's internal
logs and we don't want the output to include slapd's own logs.

```
sudo /usr/sbin/slapd -h 'ldap:/// ldapi:///' -g openldap -u openldap -f /etc/ldap/slapd.conf -d 0
```

1. In addition, tail essential log files:

```
sudo tail -f /var/log/syslog /var/log/dhcp-ldap-startup.log
```

### Troubleshooting DHCP Server

DHCP server will issue the equivalent of the following LDAP searches upon startup:

```
ldapsearch -a never -b ou=dhcp -s sub -x "(&(objectClass=dhcpServer)(cn=HOSTNAME))"
```

There are many DHCP-related problems that can come up, preventing the server from starting.

A good rule of thumb is to make sure that there is at least some network interface configured with the IP 10.0.1.1/24. This is one of test subnets loaded along with test data, and it should allow the DHCP server to start.

Also, when adding new clients, it is mandatory to create the network interface or alias and set it to an IP from the desired subnet before adding the new client and DHCP block to LDAP and restarting DHCP.



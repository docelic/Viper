# Viper

Viper is a system for fully automated installation, configuration and monitoring of Debian GNU based systems. The development started in 2008.

Viper uses a modern approach (debian-installer during installation, configuration management tool later, etc.), works with existing Debian packages, and does not require any custom patching of either install media, client, or server.

The basis of the whole system is an OpenLDAP server with a custom Viper backend with radically new and dynamic functionality, and holding all configuration data.

## Introduction

LDAP has the potential to be enormously successful in configuration management, but its flat data structure, absence of any kind of dynamic behavior, and heaps of duplicated data typically make it an inefficent tool for smaller teams.

Using LDAP for complex configuration management in a seamless, successful, non-intrusive way has been reserved for high-end customers who have invested significant resources into making it work as desired in their environments.

Viper was developed to build on LDAP's great strengths while solving many of its typical deficiencies when it comes to configuration management.

As part of Viper, a custom OpenLDAP backend has been implemented, and an important side-property of a custom backend became apparent &mdash; the ability to adapt to a wide range of existing software and their specifics of accessing LDAP, instead of possibly requiring modifications to their source code to glue it all together.

Finally, one of the design goals was to make Viper just feel right and easy to get results with. So, everything has been commented, with the availability of complete, working config files and this guide.

Viper is released under GNU GPL v3 or later.

## Features Overview

Here follows a summarized list of Viper's key features, especially those that may differ from traditional config management or LDAP principles. (The explanations on how or why Viper does what it does can be found in other sections below; this section focuses only the high-level summary of user functionality.)

Viper relies on Debconf, OpenLDAP, ISC DHCP, and a software configuration management tool (such as Puppet) for full operation.

One Viper server instance can store and serve data for multiple separate customers, with multiple separate machines each.

Viper "rewrites" incoming LDAP searches in numerous ways, completely avoiding duplication of data, while at the same time transparently handling all clients who issue their standard LDAP queries and expect to find information in their standard locations.

With the help of a CGI script, Viper also handles clients who don't use LDAP searches but request data over HTTP, such as clients requesting preseed data at the beginning of machine installation.

After the machine has been initially installed, machines' Debconf settings (as well as config management software's settings) are configured to use Debconf LDAP backend and query the Viper server for information.

All Viper's configuration-related key=value pairs are stored in Debconf's LDAP schema (objectClass = `debconfDbEntry`). This makes it possible to treat all keys equally, regardless of whether they are part of the mandatory preseed contents, or non-essential Debconf questions, or custom additional configuration data added by site administrators.

The usual (non-Viper) way for system administrators to preseed Debconf in advance is to extract the packages' Debconf question templates, answer them, and save them to the Debconf database, so that the questions and answers are already there when the clients ask for them. However, extracting and answering Debconf questions ahead of time and with only machine-level granularity is quite a nuisance, especially when the packages or questions needed are not known in advance or there are many dependencies to handle as well.

Viper makes it possible to answer all known/existing questions automatically as usual, while all new/unseen questions are either shown interactively at the machine being installed, or they can open a Debconf popup window on the administrator's remote host of choice. This way, they can be answered from a central location regardless of where on the network a package is being installed, and then the answers can be saved to Debconf as expected for all future queries.

Furthermore, for every Debconf question that is asked (locally or remotely), an additional follow-up question is presented to the user, allowing him to insert the answer in LDAP at the individual machine level (applying only to that machine), at the customer level (applying to all customer's machines), or at the global level (applying to all machines of all customers).

## Server Choice and Setup

Viper comes with the mentioned custom backend for OpenLDAP and that backend must be installed for Viper to work. The backend is a primary component of Viper and it implements numerous features that make Viper an extremely powerful tool for configuration management.

Please note that the Viper OpenLDAP backend is implemented in Perl and it depends on OpenLDAP's `slapd-perl`, which is subject to a couple important notes:

1. OpenLDAP's `slapd-perl` never had a robust implementation, and in newer versions of OpenLDAP it must be explicitly enabled during OpenLDAP build
1. While Viper's backend is a full-fledged piece of software, it is bound by some limitations of `slapd-perl`
1. The two primary `slapd-perl` limitations are 1) very modest access controls, and 2) incomplete API which makes most of slapd's data not directly accessible to Perl (thus requiring some duplication of configuration)

Furthermore, given's Viper very specific and contextualized purpose, for maximum convenience the default Viper config files reinstate the old and simple `slapd.conf` style of configuration instead of the new (and much more complex) `cn=config` style.

Therefore, all things considered, we advise to only run Viper on dedicated machines and inside local/trusted networks, unless you first read this guide in entirety and possibly send us patches to make Viper "thougher" and suitable for other environments.

### Introduction

The easiest way to start with Viper is to clone the files from Git and place them in `/etc/ldap/viper/`:

```
mkdir -p /etc/ldap
cd /etc/ldap
git clone git://github.com/crystallabs/Viper.git viper
cd viper
```

### Net::LDAP::FilterMatch.pm Fix

In Perl module Net::LDAP prior to version 0.4001 (2010 and earlier) there was a [bug in FilterMatch escaping](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=540938).
If you happen to be using one of those older versions, please upgrade or manually apply patch [support/FilterMatch.pm.patch](https://github.com/docelic/Viper/blob/master/support/FilterMatch.pm.patch).

### Installation Procedure

There is a very simple shell script [scripts/viper-setup.sh](https://github.com/docelic/Viper/blob/master/scripts/viper-setup.sh) delivered with Viper which contains the list of steps to be performed on a server machine to install Viper. After a mandatory manual review you could run this script to perform the installation. The script is idempotent; running it multiple times will result in no adverse effects, so in case anything fails, you can resolve the conditions and then run the script again.

In summary, to carry out the installation, you will:

1. Find a suitable Devuan GNU+Linux, Debian GNU, or Ubuntu machine to use as Viper install server
1. Decide on the machine's hostname
1. Find name of the network interface on which Viper's DHCP server will be listening
1. Install required packages: `apt install slapd ldap-utils libfile-find-rule-perl libnet-ldap-perl libtext-csv-xs-perl liblist-moreutils-perl isc-dhcp-server-ldap make sudo libyaml-perl apache2`
1. Verify and run script `scripts/viper-setup.sh` (or manually execute lines from it)
1. Make final adjustments to config files if necessary
1. Restart OpenLDAP
1. Review and/or modify LDIF data and load it into the server
1. Restart ISC DHCP
1. Run a couple tests to verify successful installation

More detailed descriptions of some of these steps follow:

#### Machine and Ethernet Interface Name

If you don't pick a specific server machine name, use the default of `viper`.

If you don't pick a specific ethernet interface to listen on, use the default of `sharedNetwork`.

#### Required Package Installations

The packages needed to run Viper have been listed above.

The HTTP server is included in the list because Viper uses a simple CGI script to provide preseed data via HTTP for client machines during installation (queried automatically from debian-installer). Our example uses Apache, even though any web server that can execute CGI will do just as well.

When installing OpenLDAP, feel free to answer "Yes" to the debconf question "Omit OpenLDAP server configuration?", because the complete config file comes supplied with Viper, and you can further tune it from there if desired.

It is known and expected that OpenLDAP and DHCP server will not start cleanly during the `apt install` step. You will install the appropriate config files for both services later, from Viper's templates.

#### Viper's Etc Config Files

Viper does not intend to unconditionally or inflexibly replace your services' config files with its own. You can just as easily manually modify any of your existing services' config files to insert parts of configurations needed by Viper.

However, it is generally assumed that you will dedicate a physical or virtual machine to the Viper server, and in that context, Viper's default config files will easily replace the services' ones and provide you with a known-good setup on which you can run the test suite and to which you can then add your own configuration. 

`viper-setup.sh` will copy all the required files from `$VIPER_ROOT/ldifs/` (which is usually `/etc/ldap/viper/ldifs`) into the system's `/etc/` and overwrite any existing files.
Currently, this includes config files for OpenLDAP, ISC DHCP, and Puppet.

#### Viper LDIFs

`viper-setup.sh` will also load the necessary bootstrap LDIFs into LDAP as part of the installation procedure. The only LDIF file that could be modified in case you will be loading the LDIFs manually is `ldifs/1-dhcp.ldif`, containing the server machine's hostname and network interface to listen on.

However, for maximum convenience, Viper comes with a default adjusted configuration that doesn't even require changes to `ldifs/1-dhcp.ldif` be made before loading the LDIF data.

The LDIF contents are supposed to load into the custom Viper backend for OpenLDAP, which comes pre-configured in Viper's OpenLDAP config files.
Therefore, be sure to restart OpenLDAP with the new configuration before loading the LDIFs.

LDIFs are loaded by simply running `make` in the directory `ldifs/`. The Makefile, in turn, runs `sh add`, which finds all `*.ldif` files in the directory and loads them using `ldapadd` and the preconfigured bind credentials.

Once the LDIFs are loaded, please restart ISC DHCP server.

#### Preseed CGI Script

Viper ships with `scripts/preseed`, a CGI script used for providing preseed data to Debian-based clients. The preseed format is natively supported by Debian installer, requiring no modifications on the client. On incoming requests, the script runs and uses the client IP to search for matching `dhcpHWAddress` and `ipHostNumber` in the LDAP directory. Then it compiles the preseed file contents and delivers them back to the client.

For maximum convenience and manual testing, the preseed data for a client can also be obtained by accessing the CGI script with query parameter `host=HOSTNAME`, and additionally with `client=DOM.AIN` if the LDAP search for hostname alone would find more than one result.





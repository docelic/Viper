# Viper

Viper is a system for fully automated installation, configuration and monitoring of Debian GNU based systems. The development started in 2008.

Viper uses a modern approach (debian-installer, etc.), works with existing Debian packages, and does not require any custom patching of either install media, client or server.

The basis of the whole system is a OpenLDAP server with a custom Viper backend, containing all configuration data.

## Introduction

LDAP has the potential to be enormously successful in configuration management, but its flat data structure, absence of any kind of dynamic behavior, and heaps of duplicated data make it a mediocre tool.

Using LDAP for complex configuration management in a seamless, non-intrusive way has been reserved for high-end environments who can invest significant resources into making it work.

Viper was developed to build on LDAP's great strengths while solving its typical deficiencies when it comes to configuration management.

As part of the effort, a custom OpenLDAP backend has been implemented, and one important benefit of a custom backend became apparent &mdash; the ability to adapt to a wide range of existing software and their specifics of accessing LDAP, instead of possibly requiring modifications to their source code.

Finally, one of the design goals was to make Viper natural and easy to get results with. For that purpose, everything has been commented, with the availability of complete config files and a Quick Start guide.

Viper is released under GNU GPL v3 or later.

## Features Overview

Here follows a summarized list of Viper's key features, and especially those that may differ from traditional config management or LDAP principles. (The explanations how or why Viper does what it does can be found in other sections below; this section focuses on the summary of usable functionality.)

Viper relies on Debconf, OpenLDAP, ISC DHCP, and a software configuration management tool (such as Puppet) for full operation.

One Viper server instance can store and serve data for multiple separate customers, with multiple machines each.

Viper can "rewrite" incoming LDAP searches in numerous ways, making it possible to completely avoid any duplication of data in its hierarchy while transparently handling all clients who issue various forms of LDAP searches and expect to find information in their usual places. (Or who don't even use LDAP searches but completely different methods, such as is the case with clients requesting preseed data over HTTP at the beginning of the installation).

All configuration-related key=value pairs are stored in Debconf's LDAP schema (objectClass = `debconfDbEntry`). This makes it possible to treat all keys equally, regardless of whether they are part of mandatory preseed contents, or later Debconf questions, or custom keys added by site administrators.

The design goal with Viper is to minimize or reduce the need for interactivity during package installation and configuration. This is, in general, done by extracting the packages' Debconf question templates, answering them, and saving both the questions and answers to the Debconf database, so that they are already found when the client looks for them and that no unnecessary prompts are shown to users. However, extracting and answering Debconf questions ahead of time would be quite a nuisance, especially if all the packages and/or questions which would be needed are not known ahead of time. Viper makes it possible that all existing questions are asked/answered automatically, and all new/unseen questions are opened as a popup window on the administrator's remote host of choice, where they can all be answered from a central location and then saved to Debconf as usual for all future queries.

Additionally, each question and answer can be inserted in LDAP at the individual machine level (applying only to that machine), at the customer level (applying to all customer's machines), or at the global level (applying to all machines of all customers).

## Server Setup

Viper comes with a complete custom backend for OpenLDAP. This backend must be installed for Viper to work, and it contains numerous features that make Viper an extremely powerful tool for configuration management.

Please note that this backend is implemented in Perl and depends on OpenLDAP's `slapd-perl`, which is subject to a couple important notes:

1. OpenLDAP's `slapd-perl` never had a sound implementation, and in newer versions of OpenLDAP it must be explicitly enabled during OpenLDAP build
1. While Viper's backend is a full-fledged piece of software, it is bound by the limitations of `slapd-perl`
1. The two primary `slapd-perl` limitations are 1) very modest access controls, and 2) incomplete API which makes most of slapd's data not directly accessible to Perl (and thus requiring some duplication of configuration)

Furthermore, given's Viper very specific and contextualized purpose, for maximum convenience the default Viper config files reinstate the old and simple `slapd.conf` style of configuration instead of the new (and much more complex) `cn=config` style. (We believe this is the right decision in this particular case.)

Therefore, all things considered, we advise to run Viper on machines dedicated to Viper, and inside local/trusted networks.

### Introduction

The easiest way to start is to clone the files from Git and place them in `/etc/ldap/viper/`:

```
mkdir -p /etc/ldap
cd /etc/ldap
git clone git://github.com/docelic/Viper.git viper
cd viper
```

### Net::LDAP::FilterMatch.pm Fix

In Perl module Net::LDAP prior to version 0.4001 there is a [bug in FilterMatch escaping](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=540938).
If you happen to be using one of the older versions, please upgrade or manually apply patch [support/FilterMatch.pm.patch](https://github.com/docelic/Viper/blob/master/support/FilterMatch.pm.patch).

### Installation Procedure

There is a very simple shell script [scripts/viper-setup.sh](https://github.com/docelic/Viper/blob/master/scripts/viper-setup.sh) delivered with Viper which contains the list of steps that need to be performed on the server machine to install Viper, and after a mandatory manual review you could even run it-as is to install Viper.

However, here's some additional context and a summarized list of install steps:

1. Find a suitable Devuan GNU+Linux, Debian GNU, or Ubuntu machine to use as Viper install server
1. Decide on the machine's hostname
1. Find name of the network interface on which Viper's DHCP and other services will be listening
1. Install required packages: `apt install slapd ldap-utils libfile-find-rule-perl libnet-ldap-perl libtext-csv-xs-perl liblist-moreutils-perl isc-dhcp-server-ldap make sudo libyaml-perl apache2`
1. Install Viper's etc config files over the default ones
1. Review and/or modify LDIF data and load it into the server

More detailed descriptions of some of these steps:

#### Required Package Installations

Viper uses a simple CGI script to provide preseed data via HTTP for client machines being installed. Our example uses Apache, even though any web server which can execute CGI will do just as well.

When installing OpenLDAP, feel free to answer "Yes" to the debconf question "Omit OpenLDAP server configuration?", because the complete config file comes supplied with Viper, and you can further tune it from there if desired.

It is expected that OpenLDAP and DHCP server will not start cleanly during the `apt install` step. You will install the appropriate config files for both services later, from Viper's templates.

#### Viper's Etc Config Files

Viper does not intend to unconditionally or inflexibly replace your services' config files with its own. You can just as easily manually modify any of your existing services' config files to do what needs to be done for Viper.

However, it is generally assumed that you will dedicate a physical or virtual machine to the Viper server, and in that context, Viper's default config files will easily replace the services' ones and provide you with a known-good setup on which you can run the test suite or to which you can add your own configuration. 

`viper-setup.sh` will copy all the required files from `$VIPER_ROOT/ldifs/` (which is usually `/etc/ldap/viper/ldifs`) into the system's `/etc/` and overwrite any existing files.
Currently, this includes config files for OpenLDAP and ISC DHCP.

#### Viper LDIFs

`viper-setup.sh` will also load the necessary bootstrap LDIFs into LDAP as part of the installation procedure. The only LDIF file that could be modified in case you will be loading the LDIFs manually is `ldifs/1-dhcp.ldif` which contains server machine's hostname and network interface to listen on.

However, for maximum convenience, Viper comes with a default adjusted configuration that does not even require these changes to `ldifs/1-dhcp.ldif` be made before loading the LDIF data.

The LDIF contents are supposed to load into the custom Viper backend for OpenLDAP, which comes pre-configured in Viper's OpenLDAP config files.
Therefore, be sure to restart OpenLDAP with the new configuration before loading the LDIFs.

LDIFs are loaded by running `make` in the directory `ldifs/`. The Makefile, in turn, runs `sh add`, which finds all `*.ldif` files in the directory and loads them using `ldapadd` and the preconfigured bind credentials.

Once the LDIFs are loaded, please restart ISC DHCP server.

#### Preseed CGI Script

Viper ships with `scripts/preseed`, a CGI script used for providing preseed data to Debian-based clients. The preseed format is natively supported by Debian installer, requiring no modifications on the client. On incoming requests, the script runs and uses the client IP to search for matching `dhcpHWAddress` and `ipHostNumber` in the LDAP directory. Then it compiles the preseed file contents and delivers them back to the client.

For maximum convenience and manual testing, the preseed can also be obtained by accessing the CGI script with query parameter `host=HOSTNAME`, and additionally with `client=DOM.AIN` if the LDAP search for hostname alone would find more than one result.


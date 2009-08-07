# Install necessary packages
apt-get install slapd ldap-utils libfile-find-rule-perl libnet-ldap-perl libtext-csv-xs-perl liblist-moreutils-perl dhcp3-server-ldap make sudo libyaml-perl

# Download files to right places
cd /etc/ldap
wget http://www.spinlocksolutions.com/viper-nightly.tar.bz2
tar jxf viper-nightly.tar.bz2

# Install slapd.conf as symlink to Viper's version
mv slapd.conf slapd.conf.orig
cp -s viper/configs/slapd.conf .

# Copy schemas over
cd /etc/ldap/schema
mkdir orig
mv * orig
cp -s ../viper/configs/{*schema,schema.ldif} .

# One-time viper subdirectory creation
mkdir /var/lib/ldap/viper
chown openldap:openldap /var/lib/ldap/viper

# Restart slapd with new configs and all. You MUST use the LD_PRELOAD
# environment variable, or you'll receive an error like this:
# /usr/sbin/slapd: symbol lookup error:
#   /usr/lib/perl/5.10/auto/IO/IO.so: undefined symbol: Perl_Istack_sp_ptr
# This is an error caused by Debian's decision to configure libtool to make
# dynamic library loading only export symbols to the calling process or
# whatever, and not to other libraries loaded after it.
# So an easy solution to a somewhat complicated issue is to manually
# add the LD_PRELOAD= option as shown, and do it in anything that deals
# with slapd (including its init script).
LD_PRELOAD=/usr/lib/libperl.so.5.10 invoke-rc.d slapd restart

# Sync Viper schema to server schema
# Not needed because the set of schemas we deliver and schema.ldif are
# already in sync.
#perl /etc/ldap/viper/scripts/schema.pl > /etc/ldap/schema/schema.ldif
#LD_PRELOAD=/usr/lib/libperl.so.5.10 invoke-rc.d slapd restart

# Adjust local server name in dhcp.ldif:
# Replace "s1" in ldifs/dhcp.ldif with the name of local server:
cd /etc/ldap/viper/ldifs
perl -pi -e 'BEGIN{ $h= `hostname`; chomp $h}; s/s1/$h/g' dhcp.ldif

# Load LDIF data into LDAP (NOTE: 'make' deletes all Viper data from LDAP
# and then loads all *ldif files, so if you want to use this approach, do not
# modify LDAP entries directly as changes will be lost -- instead, always edit
# LDIF file and run make)
cd /etc/ldap/viper/ldifs
make

# Place new dhcp config file, restart dhcp
cd /etc/dhcp3
mv dhcpd.conf dhcpd.conf.orig
cp -s ../ldap/viper/configs/dhcpd.conf .
invoke-rc.d dhcp3-server restart

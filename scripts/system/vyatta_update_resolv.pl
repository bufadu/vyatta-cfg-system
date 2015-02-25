#!/usr/bin/perl -w
#
# Module: vyatta_update_resolv.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Marat Nepomnyashy
# Date: December 2007
# Description: Script to update '/etc/resolv.conf' on commit of 'system domain-search domain' config.
#
# **** End License ****
#

use strict;
use lib "/opt/vyatta/share/perl5/";
use Getopt::Long;
use Vyatta::Config;

my $dhclient_script = 0;
my $config_mode = 0;
GetOptions("dhclient-script=i" => \$dhclient_script,
           "config-mode=i"     => \$config_mode,
);

my $vc = new Vyatta::Config();
$vc->setLevel('system');

my @domains;
my $domain_name = undef;
my $disable_dhcp_nameservers = undef;

if ($config_mode == 1) {
    $disable_dhcp_nameservers = $vc->exists('disable-dhcp-nameservers');
} else {
    $disable_dhcp_nameservers = $vc->existsOrig('disable-dhcp-nameservers');
}

if ($dhclient_script == 1) {
    @domains = $vc->returnOrigValues('domain-search domain');
    $domain_name = $vc->returnOrigValue('domain-name');
} else {
    @domains = $vc->returnValues('domain-search domain');
    $domain_name = $vc->returnValue('domain-name');
}

if ($dhclient_script == 0 && @domains > 0 && $domain_name && length($domain_name) > 0) {
    my @loc;
    if ($vc->returnOrigValues('domain-search domain') > 0) {
        @loc = ["system","domain-name"];
    }
    else {
        @loc = ["system","domain-search","domain"];
    }
    Vyatta::Config::outputError(@loc,"System configuration error.  Both \'domain-name\' and \'domain-search\' are specified, but only one of these mutually exclusive parameters is allowed.");
    exit(1);
}

my $doms = '';
foreach my $domain (@domains) {
    if (length($doms) > 0) {
        $doms .= ' ';
    }
    $doms .= $domain;
}

# add domain names received from dhcp client to domain search in /etc/resolv.conf if domain-name not set in CLI

if (!defined($domain_name)) {
    my @dhcp_interfaces_resolv_files = `ls /etc/ | grep resolv.conf.dhclient-new`;
    if ($#dhcp_interfaces_resolv_files >= 0) {
        for my $each_file (@dhcp_interfaces_resolv_files) {
            chomp $each_file;
            my $find_search = `grep "^search" /etc/$each_file 2> /dev/null | wc -l`;
            if ($find_search == 1) {
                my $search_string = `grep "^search" /etc/$each_file`;
                my @dhcp_domains = split(/\s+/, $search_string, 2);
                my $dhcp_domain = $dhcp_domains[1];
                chomp $dhcp_domain;
                $doms .= ' ' . $dhcp_domain;
            }
        }
    }
}

my $search = '';
if (length($doms) > 0) {
    $search = "#line generated by $0\nsearch\t\t$doms\n";
}

my $domain = '';
if ($domain_name && length($domain_name) > 0) {
    $domain = "#line generated by $0\ndomain\t\t$domain_name\n";
}

# update /etc/resolv.conf with name-servers received from dhcp client, done when this script is called
# with either the dhclient-script (on DHCP changes) or config-mode (disable-dhcp-nameservers) options.

if (($dhclient_script == 1) || ($config_mode == 1)) {
    my @current_dhcp_nameservers;
    my $restart_ntp = 0;

    # code below to add new name-servers received from dhcp client, but only if disable-dhcp-nameservers 
    # hasn't been enabled.
    
    my @dhcp_interfaces_resolv_files = `ls /etc/ | grep resolv.conf.dhclient-new`;
    if ($#dhcp_interfaces_resolv_files >= 0) {
        my $ns_count = 0;
        for my $each_file (@dhcp_interfaces_resolv_files) {
            chomp $each_file;
            my $find_nameserver = `grep nameserver /etc/$each_file 2> /dev/null | wc -l`;
            if ($find_nameserver > 0) {
                my @nameservers = `grep nameserver /etc/$each_file`;
                for my $each_nameserver (@nameservers) {
                    my @nameserver = split(/ /, $each_nameserver, 2);
                    my $ns = $nameserver[1];
                    chomp $ns;
                    $current_dhcp_nameservers[$ns_count] = $ns;
                    $ns_count++;
                    my @search_ns_in_resolvconf = `grep $ns /etc/resolv.conf`;
                    my $ns_in_resolvconf = 0;
                    if (@search_ns_in_resolvconf > 0) {
                        foreach my $ns_resolvconf (@search_ns_in_resolvconf) {
                            my @resolv_ns = split(/\s+/, $ns_resolvconf);
                            my $final_ns = $resolv_ns[1];
                            chomp $final_ns;
                            if ($final_ns eq $ns) {
                                $ns_in_resolvconf = 1;
                            }
                        }
                    }
                    if (($ns_in_resolvconf == 0) && !($disable_dhcp_nameservers)) {
                        open (my $rf, '>>', '/etc/resolv.conf')
                            or die "$! error trying to overwrite";
                        print $rf "nameserver\t$ns\t\t#nameserver written by $0\n";
                        close $rf;
                        $restart_ntp = 1;
                    }
                }
            }
        }
    }

    # code below to remove old name-servers from /etc/resolv.conf that were not received in this response
    # from dhcp-server, or to remove previous dhcp supplied name-servers if disable-dhcp-nameservers has
    # been enabled.

    my @nameservers_dhcp_in_resolvconf = `grep 'nameserver written' /etc/resolv.conf`;
    my @dhcp_nameservers_in_resolvconf;
    my $count_nameservers_in_resolvconf = 0;
    for my $count_dhcp_nameserver (@nameservers_dhcp_in_resolvconf) {
        my @dhcp_nameserver = split(/\t/, $count_dhcp_nameserver, 3);
        $dhcp_nameservers_in_resolvconf[$count_nameservers_in_resolvconf] = $dhcp_nameserver[1];
        $count_nameservers_in_resolvconf++;
    }
    if (($#current_dhcp_nameservers < 0) || ($disable_dhcp_nameservers)) {
        for my $dhcpnameserver (@dhcp_nameservers_in_resolvconf) {
            my $cmd = "sed -i '/$dhcpnameserver\t/d' /etc/resolv.conf";
            system($cmd);
            $restart_ntp = 1;
        }
    } else {
        for my $dhcpnameserver (@dhcp_nameservers_in_resolvconf) {
            my $found = 0;
            for my $currentnameserver (@current_dhcp_nameservers) {
                if ($dhcpnameserver eq $currentnameserver){
                    $found = 1;
                }
            }
            if ($found == 0) {
                my $cmd = "sed -i '/$dhcpnameserver\t/d' /etc/resolv.conf";
                system($cmd);
                $restart_ntp = 1;
            }
        }
    }
    if ($restart_ntp == 1) {
        # this corresponds to what is done in name-server/node.def as a fix for bug 1300
        my $cmd_ntp_restart = "if [ -f /etc/ntp.conf ] && grep -q '^server' /etc/ntp.conf; then /usr/sbin/invoke-rc.d ntp restart >&/dev/null; fi &";
        system($cmd_ntp_restart);
    }
}

# The following will re-write '/etc/resolv.conf' line by line,
# replacing the 'search' specifier with the latest values,
# or replacing the 'domain' specifier with the latest value.

my @resolv;
if (-e '/etc/resolv.conf') {
    open (my $f, '<', '/etc/resolv.conf')
        or die("$0:  Error!  Unable to open '/etc/resolv.conf' for input: $!\n");
    @resolv = <$f>;
    close ($f);
}

my $foundSearch = 0;
my $foundDomain = 0;

open (my $r, '>', '/etc/resolv.conf')
    or die("$0:  Error!  Unable to open '/etc/resolv.conf' for output: $!\n");

foreach my $line (@resolv) {
    if ($line =~ /^search\s/) {
        $foundSearch = 1;
        if (length($search) > 0) {
            print $r $search;
        }
    } elsif ($line =~ /^domain\s/) {
        $foundDomain = 1;
        if (length($domain) > 0) {
            print $r $domain;
        }
    } elsif ($line !~ /^#line generated by\s/) {
        print $r $line;
    }
}

if ($foundSearch == 0 && length($search) > 0) {
    print $r $search;
}
if ($foundDomain == 0 && length($domain) > 0) {
    print $r $domain;
}

close ($r);

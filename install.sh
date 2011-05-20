#!/bin/bash

set +x

exec >/tmp/firstboot.local
exec 2>&1

touch /tmp/foo
#many parts of this flagrantly stolen from http://www.stgraber.org/2011/05/04/state-of-lxc-in-ubuntu-natty/

# set up /etc/hosts for dns resolution
echo >> /etc/hosts
echo '#swift lab hosts' >> /etc/hosts
i=11
for srv in proxy01 storage0{1..3}; do 
  echo 192.168.254.$i $srv $srv.swift
  i=$[ i + 1 ]
done >> /etc/hosts

# Installed required packages
apt-get install lxc debootstrap bridge-utils dnsmasq dnsmasq-base loop-aes-utils libcap2-bin sharutils open-iscsi iscsitarget open-iscsi-utils

# Add a new bridge for LXC, including NAT rule
(
cat << EOF

# LXC bridge
auto br-lxc
iface br-lxc inet static
    address 192.168.254.1
    netmask 255.255.255.0

    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    pre-down echo 0 > /proc/sys/net/ipv4/ip_forward
    pre-down iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

    bridge_ports none
    bridge_stp off
EOF
) >> /etc/network/interfaces
ifup br-lxc

# Create a mountpoint and mount cgroup
mkdir /cgroup
(
cat << EOF
cgroup /cgroup cgroup
EOF
) >> /etc/fstab
mount /cgroup

# Basic configuration for networking
(
cat << EOF
lxc.network.type = veth
lxc.network.flags = up
lxc.network.link = br-lxc
EOF
) > /etc/lxc/network.conf

#download and extract containers

#configure shared directory in containers
mkdir /var/lib/lxc/{proxy01,storage0{1..3}}/rootfs/shared
for point in  /var/lib/lxc/{proxy01,storage0{1..3}}/rootfs/shared; do mount /var/lib/lxc/shared $point -o bind; done

#make "disks" for lxc containers
mkdir -p /var/lib/swift
for f in disk{1..6}; do dd if=/dev/zero of=/var/lib/swift/$f count=0 bs=1024 seek=1000000; done

#configure iscsi to expose disks to localhost
> /etc/iet/ietd.conf
for i in {1..6}; do
  echo "Target iqn.2011-05.swift.storage:storage.disk$i" >> /etc/iet/ietd.conf
  echo "    Lun 0 Path=/var/lib/swift/disk$i,Type=fileio" >> /etc/iet/ietd.conf
done

echo "ALL 127.0.0.0/8" | tee /etc/iet/{initiators,targets}.allow
echo 'ISCSITARGET_ENABLE=true' > /etc/default/iscsitarget
/etc/init.d/iscsitarget restart

perl -pi -e 's/^node.startup = manual/node.startup = automatic/;' /etc/iscsi/iscsid.conf
iscsiadm -m discovery -t st -p 127.0.0.1

#!/bin/bash

set +x

exec >/tmp/firstboot.local
exec 2>&1

export PATH=/bin:/usr/bin:/usr/sbin:/sbin

#many parts of this flagrantly stolen from http://www.stgraber.org/2011/05/04/state-of-lxc-in-ubuntu-natty/


# set up ssh key -- REPLACE THIS WITH YOUR KEY
mkdir /root/.ssh
cat > /root/.ssh/authorized_keys <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDD6BZiV4WdZRhF1TWW1ywvnvYp9gguRI4NMYZP6F5SbOshB08LuDn2A7aeeBrW5Xphbmx8O02sL3Tn1kw6fdYvdjNOqHZgMJyblWABuUc8ZHDlS72hBXxtqu2pcyJ6GOeJZWyNurdBsRm+YQtZ+/gHKm36fUot8UC0quJYPmJJ1FzymKd0aT5lbixR6p00Bx+I+He+XiPbwVe2A3JN04dvOPlcp9kQDhdADXdMS9qgR1X9HVgZ91hbm9ng4emdzT4xqD73vAKwngGgkNNaICNoartH9ck1pplOkvij36suJyU55rTBy5HKSiLIOpVoq/RePHjmVidIuWNtjxBDOtLh rpedde@dell-laptop
EOF
chmod -R ow-rwx /root/.ssh

# set up /etc/hosts for dns resolution
echo >> /etc/hosts
echo '#swift lab hosts' >> /etc/hosts
i=11
for srv in proxy01 storage0{1..3}; do 
  echo 192.168.254.$i $srv $srv.swift
  i=$[ i + 1 ]
done >> /etc/hosts

# fix up missing asm-offsets.h
apt-get install -y  linux-headers-`uname -r` gawk

ln -nsf /usr/src/linux-headers-`uname -r`/include/asm-x86 /usr/src/linux-headers-`uname -r`/include/asm

# Installed required packages
apt-get install -y lxc debootstrap bridge-utils dnsmasq dnsmasq-base loop-aes-utils libcap2-bin sharutils open-iscsi open-iscsi-utils iscsitarget-dkms

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
    bridge_fd 0
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
#container creation
LXCDIR=/var/lib/lxc
n=192.168.254
h=11
g=1
l=1
for srv in {proxy01,storage0{1..3}}; do
  ROOT=$LXCDIR/$srv/rootfs
  lxc-create -n $srv -t ubuntu -f /etc/lxc/network.conf
  (
  cat <<EOF > $ROOT/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $n.$h
    netmask 255.255.255.0
    gateway $n.$g
EOF
  )
  rm $ROOT/etc/resolv.conf
  echo "nameserver 192.168.254.1" > $ROOT/etc/resolv.conf

done


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

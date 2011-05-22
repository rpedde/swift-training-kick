#!/bin/bash

set +x

if [ -e /tmp/firstboot.local ]; then
    mv /tmp/firstboot.local /tmp/firstboot.old
fi

exec >/tmp/firstboot.local
exec 2>&1

LXCDIR=/var/lib/lxc

export PATH=/bin:/usr/bin:/usr/sbin:/sbin

#many parts of this flagrantly stolen from http://www.stgraber.org/2011/05/04/state-of-lxc-in-ubuntu-natty/

# set up ssh key -- REPLACE THIS WITH YOUR KEY
if [ ! -e /root/.ssh/authorized_keys ]; then
    mkdir /root/.ssh
    cat > /root/.ssh/authorized_keys <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDD6BZiV4WdZRhF1TWW1ywvnvYp9gguRI4NMYZP6F5SbOshB08LuDn2A7aeeBrW5Xphbmx8O02sL3Tn1kw6fdYvdjNOqHZgMJyblWABuUc8ZHDlS72hBXxtqu2pcyJ6GOeJZWyNurdBsRm+YQtZ+/gHKm36fUot8UC0quJYPmJJ1FzymKd0aT5lbixR6p00Bx+I+He+XiPbwVe2A3JN04dvOPlcp9kQDhdADXdMS9qgR1X9HVgZ91hbm9ng4emdzT4xqD73vAKwngGgkNNaICNoartH9ck1pplOkvij36suJyU55rTBy5HKSiLIOpVoq/RePHjmVidIuWNtjxBDOtLh rpedde@dell-laptop
EOF
    chmod -R oa-rwx /root/.ssh
fi


# set up /etc/hosts for dns resolution
if ( ! grep -iq "192\.168\.254\.11" /etc/hosts ); then
    echo >> /etc/hosts
    echo '#swift lab hosts' >> /etc/hosts
    i=11
    for srv in proxy01 storage0{1..3}; do 
	echo 192.168.254.$i $srv $srv.swift
	i=$[ i + 1 ]
    done >> /etc/hosts
fi

# fix up missing asm-offsets.h
apt-get install -y  linux-headers-`uname -r` gawk

if [ ! -e /usr/src/linux-headers-`uname -r`/include/asm ]; then 
    ln -nsf /usr/src/linux-headers-`uname -r`/include/asm-x86 /usr/src/linux-headers-`uname -r`/include/asm
fi

# Installed required packages
apt-get install -y lxc debootstrap bridge-utils dnsmasq dnsmasq-base loop-aes-utils libcap2-bin sharutils open-iscsi open-iscsi-utils iscsitarget-dkms iscsitarget

# Add a new bridge for LXC, including NAT rule
if ( ! grep -q "br-lxc" /etc/network/interfaces ); then
    cat >> /etc/network/interfaces<<EOF

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

    # bridge configured, let's bring it up
    ifup br-lxc
fi

# Create a mountpoint and mount cgroup
if ( ! grep -iq "cgroup" /etc/mtab ); then
    mkdir -p /cgroup
    cat >> /etc/fstab <<EOF
cgroup /cgroup cgroup
EOF
    mount /cgroup
fi

# Basic configuration for networking
cat > /etc/lxc/network.conf <<EOF
lxc.network.type = veth
lxc.network.flags = up
lxc.network.link = br-lxc
EOF

#download and extract containers
#container creation
n=192.168.254
h=11
g=1
for srv in {proxy01,storage0{1..3}}; do
    ROOT=${LXCDIR}/${srv}/rootfs

    if [ ! -e ${LXCDIR}/${srv} ]; then
	lxc-create -n ${srv} -t ubuntu -f /etc/lxc/network.conf
    fi

    cat > $ROOT/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $n.$h
    netmask 255.255.255.0
    gateway $n.$g
EOF

  h=$((h+1))
  rm -f $ROOT/etc/resolv.conf
  echo "nameserver 192.168.254.1" > $ROOT/etc/resolv.conf
done


#configure shared directory in containers
mkdir -p /var/lib/lxc/{proxy01,storage0{1..3}}/rootfs/shared
mkdir -p /var/lib/lxc/shared

for point in /var/lib/lxc/{proxy01,storage0{1..3}}/rootfs/shared; do 
    if ( ! grep "$point" /etc/mtab ); then
	mount /var/lib/lxc/shared $point -o bind; 
    fi
done

#make "disks" for lxc containers
mkdir -p /var/lib/swift
for f in disk{1..6}; do 
    if [ ! -e /var/lib/swift/$f ]; then
	dd if=/dev/zero of=/var/lib/swift/$f count=0 bs=1024 seek=1000000
    fi
done

#configure iscsi to expose disks to localhost
> /etc/iet/ietd.conf
for i in {1..6}; do
    if ( ! grep -iq "storage\.disk$i" /etc/iet/ietd.conf ); then
	echo "Target iqn.2011-05.swift.storage:storage.disk$i" >> /etc/iet/ietd.conf
	echo "    Lun 0 Path=/var/lib/swift/disk$i,Type=fileio" >> /etc/iet/ietd.conf
    fi
done


echo "ALL 127.0.0.0/8" | tee /etc/iet/{initiators,targets}.allow
echo 'ISCSITARGET_ENABLE=true' > /etc/default/iscsitarget
/etc/init.d/iscsitarget restart

perl -pi -e 's/^node.startup = manual/node.startup = automatic/;' /etc/iscsi/iscsid.conf

iscsiadm -m discovery -t st -p 127.0.0.1

/etc/init.d/open-iscsi restart

for srv in storage0{1..3}; do
    ROOT=${LXCDIR}/${srv}/rootfs
    rm -f ${ROOT}/dev/sd{a,b}
done

# dummy up devices -- this is kind of rude
mknod ${LXCDIR}/storage01/rootfs/dev/sda b 8 0  # /dev/sda
mknod ${LXCDIR}/storage01/rootfs/dev/sdb b 8 16 # /dev/sdb
if ( ! grep -q "b 8:0" ${LXCDIR}/storage01/config ); then
    cat >> ${LXCDIR}/storage01/config <<EOF
# /dev/sd{a,b}
lxc.cgroup.devices.allow = b 8:0 rwm
lxc.cgroup.devices.allow = b 8:16 rwm
EOF
fi

mknod ${LXCDIR}/storage02/rootfs/dev/sda b 8 32 # /dev/sdc
mknod ${LXCDIR}/storage02/rootfs/dev/sdb b 8 48 # /dev/sdd
if ( ! grep -q "b 8:32" ${LXCDIR}/storage02/config ); then
    cat >> ${LXCDIR}/storage02/config <<EOF
# /dev/sd{a,b}
lxc.cgroup.devices.allow = b 8:32 rwm
lxc.cgroup.devices.allow = b 8:48 rwm
EOF
fi

mknod ${LXCDIR}/storage03/rootfs/dev/sda b 8 64 # /dev/sde
mknod ${LXCDIR}/storage03/rootfs/dev/sdb b 8 80 # /dev/sdf
if ( ! grep -q "b 8:64" ${LXCDIR}/storage03/config ); ten
    cat >> ${LXCDIR}/storage03/config <<EOF
# /dev/sd{a,b}
lxc.cgroup.devices.allow = b 8:64 rwm
lxc.cgroup.devices.allow = b 8:80 rwm
EOF
fi

# Make the lxc containers autostart
cat > /etc/default/lxc <<EOF
RUN=yes
CONF_DIR=/etc/lxc
CONTAINERS="proxy01 storage01 storage02 storage03"
EOF

# Fix up iptables
cat > /etc/firewall.conf <<EOF
EOF

# add a swift user
for srv in ${LXCDIR}; do
    if ( ! grep -q "swift" ${LXCDIR}/${srv}/rootfs/etc/passwd ); then
	chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "adduser --system --home /shared --shell /bin/bash --no-create-home swift"
    fi
done

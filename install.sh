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
apt-get install -y lxc debootstrap bridge-utils dnsmasq dnsmasq-base loop-aes-utils libcap2-bin sharutils open-iscsi open-iscsi-utils iscsitarget-dkms iscsitarget makepasswd

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
for f in disk{1..7}; do 
    if [ ! -e /var/lib/swift/$f ]; then
	dd if=/dev/zero of=/var/lib/swift/$f count=0 bs=1024 seek=1000000
    fi
done

#configure iscsi to expose disks to localhost
> /etc/iet/ietd.conf
for i in {1..7}; do
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
    rm -f ${ROOT}/dev/sd{b,c}
done

# dummy up devices -- this is kind of rude
mknod ${LXCDIR}/storage01/rootfs/dev/sdb b 8 16  # /dev/sdb
mknod ${LXCDIR}/storage01/rootfs/dev/sdb1 b 8 17  # /dev/sdb1
mknod ${LXCDIR}/storage01/rootfs/dev/sdc b 8 32 # /dev/sdc
mknod ${LXCDIR}/storage01/rootfs/dev/sdc1 b 8 33 # /dev/sdc1
if ( ! grep -q "b 8:16" ${LXCDIR}/storage01/config ); then
    cat >> ${LXCDIR}/storage01/config <<EOF
# /dev/sd{a,b}
lxc.cgroup.devices.allow = b 8:16 rwm
lxc.cgroup.devices.allow = b 8:17 rwm
lxc.cgroup.devices.allow = b 8:32 rwm
lxc.cgroup.devices.allow = b 8:33 rwm
EOF
fi

mknod ${LXCDIR}/storage02/rootfs/dev/sdb b 8 48 # /dev/sdd
mknod ${LXCDIR}/storage02/rootfs/dev/sdb1 b 8 49 # /dev/sdd1
mknod ${LXCDIR}/storage02/rootfs/dev/sdc b 8 64 # /dev/sde
mknod ${LXCDIR}/storage02/rootfs/dev/sdc1 b 8 65 # /dev/sde1
if ( ! grep -q "b 8:32" ${LXCDIR}/storage02/config ); then
    cat >> ${LXCDIR}/storage02/config <<EOF
# /dev/sd{a,b}
lxc.cgroup.devices.allow = b 8:48 rwm
lxc.cgroup.devices.allow = b 8:49 rwm
lxc.cgroup.devices.allow = b 8:64 rwm
lxc.cgroup.devices.allow = b 8:65 rwm
EOF
fi

mknod ${LXCDIR}/storage03/rootfs/dev/sdb b 8 80 # /dev/sdf
mknod ${LXCDIR}/storage03/rootfs/dev/sdb1 b 8 81 # /dev/sdf1
mknod ${LXCDIR}/storage03/rootfs/dev/sdc b 8 96 # /dev/sdg
mknod ${LXCDIR}/storage03/rootfs/dev/sdc1 b 8 97 # /dev/sdg
if ( ! grep -q "b 8:64" ${LXCDIR}/storage03/config ); then
    cat >> ${LXCDIR}/storage03/config <<EOF
# /dev/sd{a,b}
lxc.cgroup.devices.allow = b 8:80 rwm
lxc.cgroup.devices.allow = b 8:81 rwm
lxc.cgroup.devices.allow = b 8:96 rwm
lxc.cgroup.devices.allow = b 8:97 rwm
EOF
fi

# Make the lxc containers autostart
cat > /etc/default/lxc <<EOF
RUN=yes
CONF_DIR=/etc/lxc
CONTAINERS="proxy01 storage01 storage02 storage03"
EOF

for srv in proxy01 storage0{1..3}; do
    rm -f /etc/lxc/${srv}.conf
    ln -s ${LXCDIR}/${srv}/config /etc/lxc/${srv}.conf 
done


# Fix up iptables
cat > /etc/firewall.conf <<EOF
EOF

# add a swift user
for srv in proxy01 storage0{1..3}; do
    # fix up keyring issues
    chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "apt-get -y --force-yes install ubuntu-keyring"
    chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "apt-get update"

    # fix sshd
    sed -i ${LXCDIR}/${srv}/rootfs/etc/ssh/sshd_config -e 's/PermitRootLogin.*/PermitRootLogin no/'

    # install sudo
    if [ ! -e ${LXCDIR}/${srv}/rootfs/etc/sudoers ]; then
	chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "apt-get install -y sudo"
    fi

    # install dsh
    if [ ! -e ${LXCDIR}/${srv}/rootfs/usr/bin/dsh ]; then
	chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "apt-get install -y dsh"
    fi

    if [ ! -e ${LXCDIR}/${srv}/rootfs/usr/sbin/rsyslogd ]; then
	chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "apt-get install -y rsyslog"
    fi


    # add a swift user
    PWHASH=`echo "Swift^pw" | makepasswd --clearfrom=- --crypt-md5 | awk '{print $2}'`

    if ( ! grep -q "swift" ${LXCDIR}/${srv}/rootfs/etc/passwd ); then
	chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "adduser --system --home=/shared --shell=/bin/bash --no-create-home --uid=500 swift"
    fi
    chroot ${LXCDIR}/${srv}/rootfs /bin/bash -c "usermod -p '${PWHASH}' swift"

    # add sudoers
    if ( ! grep -q "swift" ${LXCDIR}/${srv}/rootfs/etc/sudoers ); then
	echo "swift ALL=(ALL) NOPASSWD:ALL" >> ${LXCDIR}/${srv}/rootfs/etc/sudoers
    fi
done

echo "Making ssh keys"

# make ssh keys
mkdir -p ${LXCDIR}/shared/.ssh
if [ ! -e ${LXCDIR}/shared/.ssh/id_rsa ]; then
    ssh-keygen -N '' -f ${LXCDIR}/shared/.ssh/id_rsa -t rsa -q
    cp ${LXCDIR}/shared/.ssh/id_rsa.pub ${LXCDIR}/shared/.ssh/authorized_keys
fi

echo "Starting LXC containers"
/etc/init.d/lxc restart

sleep 10

echo "Doing keyscan"
ssh-keyscan -t rsa proxy01 storage0{1..3} > ${LXCDIR}/shared/.ssh/known_hosts

echo "Setting up ssh and dsh"
chown -R 500 ${LXCDIR}/shared
chown -R 500 ${LXCDIR}/shared/.ssh
chmod go-rwx ${LXCDIR}/shared/.ssh

mkdir -p ${LXCDIR}/shared/.dsh/group
cat > ${LXCDIR}/shared/.dsh/group/storage <<EOF
storage01
storage02
storage03
EOF

echo "proxy01" > ${LXCDIR}/shared/.dsh/group/proxy

cat ${LXCDIR}/shared/.dsh/group/* > ${LXCDIR}/shared/.dsh/group/all

chown -R 500 ${LXCDIR}/shared/.dsh

# echo "Stopping containers"
# for srv in proxy01 storage0{1..3}; do
#     lxc-stop -n ${srv}
# done

echo "Fixing up firewall"
# Fix up iptables, and make it work after a reboot
cat > /etc/firewall.conf <<EOF
# Generated by iptables-save v1.4.4 on Sun May 22 22:29:06 2011
*nat
:PREROUTING ACCEPT [7:368]
:OUTPUT ACCEPT [661:41416]
:POSTROUTING ACCEPT [94:5736]
-A POSTROUTING -o eth0 -j MASQUERADE 
-A PREROUTING -i eth0 -p tcp -m tcp --dport 22 -j DNAT --to-destination 192.168.254.11:22 
-A PREROUTING -i eth0 -p tcp -m tcp --dport 2222 -j REDIRECT --to-port 22
COMMIT
# Completed on Sun May 22 22:29:06 2011
# Generated by iptables-save v1.4.6 on Sun May 22 22:29:06 2011
*filter
:INPUT DROP [191:14516]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [67625:4590809]
-A INPUT -i lo -j ACCEPT 
-A INPUT -d 127.0.0.0/8 ! -i lo -j REJECT --reject-with icmp-port-unreachable 
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 
-A INPUT -m tcp -p tcp --dport 22 -j ACCEPT
-A INPUT -m tcp -p tcp --dport 2222 -j ACCEPT
-A INPUT -s 192.168.254.0/22 -j ACCEPT 
COMMIT
# Completed on Sun May 22 22:29:06 2011
EOF

iptables-restore < /etc/firewall.conf

cat > /etc/network/if-up.d/firewall <<EOF
#!/bin/bash
/sbin/iptables-restore < /etc/firewall.conf
EOF

chmod +x /etc/network/if-up.d/firewall

echo "Done"


#!/usr/bin/env python

import json
import sys

import cloudservers
from optparse import OptionParser

parser = OptionParser()
parser.add_option("-c", "--configfile", dest="configfile", default=None)
parser.add_option("-u", "--username", dest="username", default=None)
parser.add_option("-k", "--key", dest="key", default = None)
parser.add_option("-n", "--number", dest="number", type="int", default=1)

(options,args) = parser.parse_args()
config_hash = {}

if options.configfile:
    config_hash = json.load(open(options.configfile,'r'))
else:
    if not (options.username and options.key):
        print "Must either pass --configfile or --username and --key options"
        sys.exit()

    config_hash['username'] = options.username
    config_hash['key'] = options.key

try:
    cs = cloudservers.CloudServers(config_hash['username'], config_hash['key'])
    cs.authenticate()
except Exception:
    # doesn't throw cloudservers.Unauthorized.  Sometimes it just
    # pukes with json ValueErrors
    print "Can't connect to cloud sites.  Check connection and config file"
    sys.exit()

# find the image we want to load

image = [ x for x in cs.images.list() if x.name.find("10.10") != -1 ][0]
print 'Installing image "%s" (id: %d)' % (image.name, image.id)

flavor = [ x for x in cs.flavors.list() if x.ram == 1024 ][0]
print 'Installing on flavor "%s" (id: %d)' % (flavor.name, flavor.id)

for x in range(1,options.number+1):
    hostname = "training-%03d" % (x,)
    print "Kicking host %s" % (hostname, )
    
    crond="* * * * * root /bin/bash /root/install.sh\n"
    root_install='#!/bin/bash\nrm -f /etc/cron.d/firstboot\napt-get install -y curl\ncurl -skS https://github.com/rpedde/swift-training-kick/raw/master/install.sh | /bin/bash\n\n'

    cs.servers.create(hostname, image.id, flavor.id, files = {
            "/etc/cron.d/firstboot": crond,
            "/root/install.sh": root_install })


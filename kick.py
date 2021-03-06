#!/usr/bin/env python

import json
import sys
import traceback

from novaclient.v1_0.client import Client
from optparse import OptionParser

parser = OptionParser()
parser.add_option("-c", "--configfile", dest="configfile", default=None)
parser.add_option("-u", "--username", dest="username", default=None)
parser.add_option("-k", "--key", dest="api_key", default=None)
parser.add_option("-n", "--number", dest="number", type="int", default=1)
parser.add_option("-o", "--offset", dest="offset", type="int", default=1)
parser.add_option("-a", "--auth-url", dest="auth_url", default=None)
parser.add_option("-g", "--git-url", dest="git_url", default="https://raw.github.com/rpedde")

(options, args) = parser.parse_args()
config_hash = {}

if options.configfile:
    config_hash = json.load(open(options.configfile, 'r'))
else:
    if not (options.username and options.api_key):
        print "Must either pass --configfile or --username and --key options"
        sys.exit()

# command line overrides conf and defaults
for opt, value in options.__dict__.items():
    if value:
        config_hash[opt] = value

cs = Client(config_hash['username'],
            config_hash['api_key'],
            None,  # TODO: fix novaclient_v1.0.Client this is retarded.
            auth_url=config_hash['auth_url'],
            )

try:
    cs.authenticate()
except Exception:
    # doesn't throw cloudservers.Unauthorized.  Sometimes it just
    # pukes with json ValueErrors
    print "Can't connect to cloud sites.  Check connection and config file"
    traceback.print_exc()
    sys.exit()

# find the image we want to load

image = [x for x in cs.images.list() if x.name.find("10.10-pvgrub") != -1][0]
print 'Installing image "%s" (id: %d)' % (image.name, image.id)

flavor = [x for x in cs.flavors.list() if x.ram == 1024][0]
print 'Installing on flavor "%s" (id: %d)' % (flavor.name, flavor.id)

if not flavor and not image:
    print "Can't find image or flavor.  :("
    sys.exit()

for x in range(options.offset, options.offset + options.number):
    hostname = "training-%03d" % (x,)
    print "Kicking host %s" % (hostname, ),

    crond = "* * * * * root /bin/bash /root/install.sh\n"
    root_install = '#!/bin/bash\nrm -f /etc/cron.d/firstboot\napt-get install -y curl\nexport GIT_URL='+options.git_url+'\ncurl -skS $GIT_URL/swift-training-kick/master/install.sh | /bin/bash\n\n'
    s = cs.servers.create(hostname, image.id, flavor.id, files={
        "/etc/cron.d/firstboot": crond,
        "/root/install.sh": root_install,
        })
    print "... %s" % (s.addresses["public"][0],)

ABOUT
=====

Simple configuration script to kickstart a Swift training cluster on Rackspace CloudServers (or Nova with OSAPI)

The script spins up a 1Gb instance, then installs LXC containers for the proxy server and three storage nodes on an internal private bridge.

Using IET, the LXC containers are presented with 2 physical devices each, which can be used as storage targets for swift.

To make this work, first create a yaml configuration file called "kick.conf" like so:

    { "username": "<cs-username>", "key": "<cs-api-key>" }

Next, make a pv-grub image of ubuntu 10.10 by [following these instructions](http://cloudservers.rackspacecloud.com/index.php/Using_a_Custom_Kernel_with_pv-grub "pv-grub").

Use the RS control panel to save the image to CloudFiles with a name like "ubuntu-10.10-pvgrub".  (The 10.10-pvgrub part is important, that's the string the script uses to find the proper image to boot).

Once that is saved, run the script, pointing it to the configuration file you created above:

    ./kick.py -n 10 -c ./kick.conf

This will create 10 instances (training-001 to training-010) ready for swift training.





In the first terminal, run `run.sh`

In another run `slirp4netns --configure --mtu=65520 $(cat /tmp/pid) tap0`

Once you do, you should start seeing traffic

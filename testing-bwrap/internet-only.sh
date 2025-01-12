term-1$ bwrap --dev-bind / / --unshare-net bash
term-1$ echo $$ > /tmp/pid
term-2$ slirp4netns --configure --mtu=65520 $(cat /tmp/pid) tap0
term-1$ curl 1.1.1.1

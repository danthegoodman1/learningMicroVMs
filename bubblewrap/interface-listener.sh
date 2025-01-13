sudo ip link add veth-host type veth peer name veth-sandbox
sudo ip link set veth-sandbox netns $(cat /tmp/pid)


# on host:
sudo ip addr add 192.168.1.1/24 dev veth-host
sudo ip link set veth-host up

# on sandbox (maybe can do this on host first?):
ip addr add 192.168.1.2/24 dev veth-sandbox
ip link set veth-sandbox up
ip link set lo up

# then find the ip address of the sandbox
ip addr show veth-sandbox

# in the sandbox, listen on the interface
nc -l 192.168.1.2 8080

# on the host, nc to it
nc 192.168.1.2 8080


# can even enable access to internet via:
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -A INPUT -i veth-host -d 127.0.0.0/8 -j REJECT


# then in sandbox
ip route add default via 192.168.1.1
# then curl the internet
curl 1.1.1.1

# prevent it from listening on localhost
sudo iptables -A INPUT -i veth-host -d 127.0.0.0/8 -j REJECT
# and on the host's interfaces
sudo iptables -A INPUT -i veth-host -d 192.168.1.1 -j REJECT

sudo rm /run/netns/test_net # reboot this is the only thing left over

sudo ip netns add test_net

sudo ip link add name veth-host type veth peer name veth-test

sudo ip link set veth-test netns test_net
sudo ip link ls
sudo ip -netns test_net link ls

sudo ip netns exec test_net ip addr add 192.168.10.1/24 dev veth-test
sudo ip netns exec test_net ip link set veth-test up
sudo ip netns exec test_net ip link set lo up
sudo ip -netns test_net addr

sudo ip link set veth-host up
sudo ip route add 192.168.10.1/32 dev veth-host
sudo ip route
sudo ip netns exec test_net ip route add default via 192.168.10.1 dev veth-test

ping -c 3 192.168.10.1

ls -l /var/run/netns

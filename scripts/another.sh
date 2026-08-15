#!/bin/bash

sudo ip netns add netns0
sudo ip link add veth0 type veth peer name ceth0
sudo ip link set veth0 up
sudo ip link set ceth0 netns netns0

sudo nsenter --net=/var/run/netns/netns0 ip link set lo up
sudo nsenter --net=/var/run/netns/netns0 ip link set ceth0 up
sudo nsenter --net=/var/run/netns/netns0 ip addr add 172.18.0.10/16 dev ceth0

sudo ip netns add netns1
sudo ip link add veth1 type veth peer name ceth1
sudo ip link set veth1 up
sudo ip link set ceth1 netns netns1

sudo nsenter --net=/var/run/netns/netns1 ip link set lo up
sudo nsenter --net=/var/run/netns/netns1 ip link set ceth1 up
sudo nsenter --net=/var/run/netns/netns1 ip addr add 172.18.0.20/16 dev ceth1

sudo ip link add name br0 type bridge
sudo ip addr add 172.18.0.1/16 dev br0
sudo ip link set br0 up
sudo ip link set veth0 master br0
sudo ip link set veth1 master br0

#sudo nsenter --net=/var/run/netns/netns0 ping -c 2 172.18.0.20
#sudo nsenter --net=/var/run/netns/netns1 ping -c 2 172.18.0.10

sudo nsenter --net=/var/run/netns/netns0 ip route add default via 172.18.0.1
sudo nsenter --net=/var/run/netns/netns1 ip route add default via 172.18.0.1

sudo bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

sudo iptables -t nat -A POSTROUTING -s 172.18.0.0/16 ! -o br0 -j MASQUERADE

# External traffic.
sudo iptables -t nat -A PREROUTING -d 10.0.2.15 -p tcp -m tcp --dport 5000 -j DNAT --to-destination 172.18.0.10:5000

# Local traffic (since it doesn't pass the PREROUTING chain).
sudo iptables -t nat -A OUTPUT -d 10.0.2.15 -p tcp -m tcp --dport 5000 -j DNAT --to-destination 172.18.0.10:5000

# https://github.com/omribahumi/libvirt_metadata_api/pull/4/files
sudo modprobe br_netfilter

# Finally, start the server in the new container.
sudo nsenter --net=/var/run/netns/netns0 python3 -m http.server --bind 172.18.0.10 5000


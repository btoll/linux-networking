#!/bin/bash

set -exo pipefail

sudo mkdir rootfs
curl http://dl-cdn.alpinelinux.org/alpine/v3.9/releases/x86_64/alpine-minirootfs-3.9.0-x86_64.tar.gz \
    | sudo tar -xz -C rootfs/
sudo chown -R "$(id -u)":"$(id -g)" rootfs
sudo unshare --net --pid --fork chroot rootfs sh

sudo ip link add name br0 type bridge
sudo ip address add 172.16.0.1/24 dev br0
sudo ip link set dev br0 up

# In another terminal, list the net namepaces and get the PID.
sudo lsns --type=net
PID=5469

# Create a veth pair and attach one end into the new net namespace.
sudo ip link add ve1 type veth peer name ve2 netns "$PID"
# The other end will be add to the bridge.
sudo ip link set dev ve1 master br0

# Add the address in the container process and bring it up.
sudo nsenter -t "$PID" -n ip address add 172.16.0.200/24 dev ve2
sudo nsenter -t "$PID" -n ip link set dev ve2 up
sudo nsenter -t "$PID" -n ip link set dev lo up # optional

# Give the other end an address and bring it up.
# ( I believe that giving it an addres is optional, but of course
#   it must be up. )
sudo ip address add 172.16.0.100/24 dev ve1
sudo ip link set dev ve1 up
sudo nsenter -t "$PID" -n ip address

# At this point, the bridge should be able to ping the other end of the pair
# in the new net namespace because the other end had been added to the bridge.
ping 172.16.0.100 -I br0
# Also, the end in the namespace should be able to ping the bridge.
sudo nsenter -t "$PID" -n ping 172.16.0.100

# Networking.
# sysctl -a | grep ip_forward
# Add default route to bridge.
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
sudo nsenter -t "$PID" -n ip route add default via 172.16.0.1
sudo iptables -A FORWARD -o eth0 -i br0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o br0 -j ACCEPT
sudo iptables -L -v
# This enables traffic back into the net namespace.
sudo iptables -t nat -A POSTROUTING -s 172.16.0.200/12 -o eth0 -j MASQUERADE

# If DNS doesn't work in the container process, try this:
#sudo mkdir -p /etc/netns/test0
#sudo touch /etc/netns/test0/resolv.conf


#!/bin/bash

set -exo pipefail

cat << EOF >> vars
namespace1=client
namespace2=server
command='python3 -m http.server'
ip_address1="10.10.10.10/24"
ip_address2='10.10.10.20/24'
interface1=veth-client
interface2=veth-server
ip_range_start='10.10.10.100'
ip_range_end='10.10.10.150'
netmask='255.255.255.0'
EOF
. vars

sudo ip netns add $namespace1
sudo ip netns add $namespace2

sudo ip link add \
       ptp-$interface1 \
       type veth \
       peer name ptp-$interface2

sudo ip link set ptp-$interface1 netns $namespace1
sudo ip link set ptp-$interface2 netns $namespace2

sudo ip netns exec $namespace1 ip addr \
     add $ip_address1 dev ptp-$interface1
sudo ip netns exec $namespace2 ip addr \
     add $ip_address2 dev ptp-$interface2
sudo ip netns exec $namespace1 ip link set \
     dev ptp-$interface1 up
sudo ip netns exec $namespace2 ip link set \
     dev ptp-$interface2 up

sudo ip netns exec $namespace2 $command &

sudo ip netns exec $namespace1 curl 10.10.10.20:8000

#---
#Now add the dchp bits.
#---

sudo ip netns exec $namespace2 ip addr add 127.0.0.1/8 dev lo
sudo ip netns exec $namespace2 ip link set lo up

sudo ip netns exec $namespace2 \
     dnsmasq --interface=ptp-$interface2 \
     --dhcp-range=$ip_range_start,$ip_range_end,$netmask

sudo ip netns exec $namespace1 ip addr\
     del $ip_address1 dev ptp-$interface1
sudo ip netns exec $namespace1 dhclient

#---
#For dns, on the host.
#---

sudo mkdir -p /etc/netns/{$namespace1,$namespace2}
sudo touch /etc/netns/$namespace{1,2}/resolv.conf


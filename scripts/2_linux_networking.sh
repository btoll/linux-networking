#!/bin/bash

set -eo pipefail

LANG=C
umask 0022

if [ -z "$1" ]
then
    printf "Usage: %s add|delete\n" "$0"
    exit 1
fi

if [ "$1" = "delete" ]
then
    # Deleting the namespace will remove the interface(s) within it and
    # the other end of the pair, both in the network device config and
    # the routing table.
    sudo ip netns delete net0
elif [ "$1" = "add" ]
then
    sudo ip netns add net0

    sudo ip link add veth0 type veth peer name ceth0

    sudo ip link set veth0 up
    sudo ip addr add 172.18.0.10/12 dev veth0

    sudo ip link set ceth0 netns net0
    sudo ip netns exec net0 ip addr add 172.18.0.20/12 dev ceth0
    sudo ip netns exec net0 ip link set ceth0 up
    sudo ip netns exec net0 ip link set lo up

    printf "ping %s\n" 172.18.0.10
    printf "ping %s\n" 172.18.0.20
    printf "ip netns list\n"
else
    printf "Unrecognized parameter \`%s\`.\n" "$1"
    exit 1
fi


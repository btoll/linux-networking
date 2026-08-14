#!/bin/bash

set -eo pipefail

LANG=C
umask 0022

if [ -z "$1" ]
then
    printf "Usage: %s add|delete\n" "$0"
    exit 1
fi

BRIDGE=br0

if [ "$1" = "delete" ]
then
    sudo ip link delete "$BRIDGE"

    for i in {0..1}
    do
        # Removing the namespace will also remove the interfaces within it,
        # which subsequently also removes the other end of the pair in the
        # root network namespace.
        sudo ip netns delete "net$i"
    done
elif [ "$1" = "add" ]
then
    sudo ip link add name "$BRIDGE" type bridge
    sudo ip address add 172.18.0.1/12 dev "$BRIDGE"
    sudo ip link set "$BRIDGE" up

    for i in {0..1}
    do
        sudo ip netns add "net$i"
        sudo ip link add "veth$i" type veth peer name "ceth$i"
        sudo ip link set "veth$i" up

        # Attach the new interfaces to the bridge device.
        sudo ip link set dev "veth$i" master "$BRIDGE"
        sudo ip link set "ceth$i" netns "net$i"

        INCREMENT=$((10 + 10 * "$i"))
        sudo ip netns exec "net$i" ip address add "172.18.0.$INCREMENT/12" dev "ceth$i"
        sudo ip netns exec "net$i" ip link set "ceth$i" up

        # Add the route to the bridge interface so the new namespaces can reach the root namespace.
        sudo ip netns exec "net$i" ip route add default via 172.18.0.1
    done

    # Enabling packet forwarding turns the machine into a router, with the
    # bridge interface acting as the default gateway for the containers.
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
else
    printf "Unrecognized parameter \`%s\`.\n" "$1"
    exit 1
fi


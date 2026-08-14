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
    for i in {0..1}
    do
        # Removing the namespace will also remove the interfaces within it,
        # which subsequently also removes the other end of the pair in the
        # root network namespace.
        sudo ip netns delete "net$i"
    done
elif [ "$1" = "add" ]
then
    for i in {0..1}
    do
        sudo ip netns add "net$i"
        sudo ip link add "veth$i" type veth peer name "ceth$i"
        sudo ip address add 172.18.0."$((100 + "$i"))"/12 dev "veth$i"
        sudo ip link set "veth$i" up
        sudo ip link set "ceth$i" netns "net$i"

        INCREMENT=$((10 + 10 * "$i"))
        sudo ip netns exec "net$i" ip address add "172.18.0.$INCREMENT/12" dev "ceth$i"
        sudo ip netns exec "net$i" ip link set "ceth$i" up
    done
else
    printf "Unrecognized parameter \`%s\`.\n" "$1"
    exit 1
fi


#!/bin/bash

ERROR="\e[31m[ERROR]\e[0m"

if [ $EUID -ne 0 ]; then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

if [ "$#" != 1 ]
then
    printf "%b This script expects only one argument, the name of the net namespace.\n" "$ERROR" 1>&2
    exit 1
fi

NS="$1"

register() {
    INDEX="${NS: -1}"
    IP=$(ip netns exec "$NS" ip addr show "ceth$INDEX" | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+')
    echo "$IP hello.local" > /etc/dnsmasq.d/hello.host
}

deregister() {
    rm /etc/dnsmasq.d/hello.host
}

trap deregister EXIT

register
ip netns exec "$NS" ./hello


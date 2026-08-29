#!/bin/bash

ERROR="\e[31m[ERROR]\e[0m"

if [ $EUID -ne 0 ]; then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

if ! command -v ipvsadm > /dev/null
then
    printf "%b \`ipvsadm\` not found within PATH.\n" "$ERROR"
    exit 1
fi

if [ "$#" != 1 ]
then
    printf "%b This script expects only one argument, the name of the net namespace.\n" "$ERROR" 1>&2
    exit 1
fi

if [ ! -f /etc/dnsmasq.d/hello.host ]
then
    echo "10.0.0.100    hello.local" > /etc/dnsmasq.d/hello.host
    ipvsadm --add-service --tcp-service 10.0.0.100:8080 --scheduler rr # round-robin
fi

NS="$1"
INDEX="${NS: -1}"
IP=$(ip netns exec "$NS" ip addr show "ceth$INDEX" | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+')

register() {
    ipvsadm --add-server --tcp-service 10.0.0.100:8080 --real-server "$IP":8080 --masquerading
}

deregister() {
    ipvsadm --delete-server --tcp-service 10.0.0.100:8080 --real-server "$IP":8080
}

trap deregister EXIT

register
ip netns exec "$NS" ./hello


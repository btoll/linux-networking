#!/bin/bash

# TODO: Ensure the range is large enough to accompany N hosts at every X IP address.

set -eo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"

if [ $EUID -ne 0 ]; then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

trap cleanup ERR

cleanup() {
    ip netns delete "$NAMESPACE" 2> /dev/null

    for ((i=0; i < HOSTS; i++))
    do
        # Removing the namespace will also remove the interfaces within it,
        # which subsequently also removes the other end of the pair in the
        # root network namespace.
        ip netns delete "${NAMESPACE}$i" 2> /dev/null
    done
}

if ! command -v ipcalc > /dev/null
then
    printf "%b \`ipcalc\` not found within PATH.\n" "$ERROR"
    exit 1
fi

usage() {
    printf "Usage: %s --op add --ns foo --cidr 172.18.0.0/20\n\n" "$0"
    printf "Args:\n"
    printf -- "--cidr      : The CIDR address.\n"
    printf -- "-n, --ns    : The name of the network namespace.\n"
    printf -- "--op        : The operation (add|delete).\n"
    printf -- "-h, --help  : Show usage.\n"
    exit "$1"
}

BRIDGE=br0
HOSTS=2

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --cidr) shift; CIDR=$1 ;;
        --hosts) shift; HOSTS=$1 ;;
        -n|--ns) shift; NAMESPACE=$1 ;;
        --op) shift; OP=$1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ -z "$OP" ]
then
    printf "%b Must provide an operation.\n" "$ERROR"
    usage 1
fi

if [ -z "$NAMESPACE" ]
then
    printf "%b Must provide a namespace.\n" "$ERROR"
    usage 1
fi

if [ "$OP" = "delete" ]
then
    cleanup
elif [ "$OP" = "add" ]
then
    # 172.18.0.0/20 - 4096 addresses
    # 172.18.0.0/21 - 2048 addresses
    # 172.18.8.0/21 - 2048 addresses

    if [ -z "$CIDR" ]
    then
        printf "%b Must provide a CIDR address.\n" "$ERROR"
        usage 1
    fi

    while IFS= read -r line
    do
        case "$line" in
            Network:*) NETWORK=$(printf "%s" "$line" | awk '{print $2}') ;;
            HostMin:*) BRIDGE_IP=$(printf "%s" "$line" | awk '{print $2}') ;;
        esac
    done <<< "$(ipcalc "$CIDR")" # We'll know if the CIDR address is invalid of the vars are empty.

    if [ -z "$NETWORK" ]
    then
        printf "%b \`%s\` is an invalid CIDR address.\n" "$ERROR" "$CIDR"
        usage 1
    fi

    NETMASK="${NETWORK#*/}"
    if [ -z "$NETMASK" ]
    then
        printf "%b CIDR address does not contain a network prefix.\n" "$ERROR"
        usage 1
    fi

    ip netns add "$NAMESPACE"
    ip -netns "$NAMESPACE" link add name "$BRIDGE" type bridge
    ip -netns "$NAMESPACE" address add "$BRIDGE_IP"/"$NETMASK" dev "$BRIDGE"
    ip -netns "$NAMESPACE" link set "$BRIDGE" up

    BASE_IP="${NETWORK%.*}"
    LAST_OCTET="${NETWORK##*.}"

    for ((i=0; i < HOSTS; i++))
    do
        ip netns add "${NAMESPACE}$i"
        ip -netns "$NAMESPACE" link add "veth$i" type veth peer name "ceth$i"
        ip -netns "$NAMESPACE" link set "veth$i" up

        # Move one end of the veth pair into the new net namespace.
        ip -netns "$NAMESPACE" link set "ceth$i" netns "${NAMESPACE}$i"

        # Attach the other end to the bridge device.
        ip -netns "$NAMESPACE" link set dev "veth$i" master "$BRIDGE"


        ip -netns "${NAMESPACE}$i" address add "$BASE_IP.$((LAST_OCTET + 10 + i))/$NETMASK" dev "ceth$i"
        ip -netns "${NAMESPACE}$i" link set "ceth$i" up
        ip -netns "${NAMESPACE}$i" route add default via "$BRIDGE_IP"
    done

    # Enabling packet forwarding turns the machine into a router, with the
    # bridge interface acting as the default gateway for the containers.
    echo 1 | tee /proc/sys/net/ipv4/ip_forward > /dev/null
else
    printf "%b Unrecognized OP parameter \`%s\`.\n" "$ERROR" "$OP"
    usage 1
fi


#!/bin/bash

set -eo pipefail

DESTROY=

BRIDGE=br0
CIDR="172.16.0.0/12"
ETH0=eth0
NET_NS=netns
NUM=1
SCRIPTNAME=$(basename "$0")
STEP=1

usage() {
    printf "veth_network

Usage: veth_network OPTIONS

Args:
--cidr=         Provide the bridge network address (defaults to 172.16.0.1/12).
--destroy, -d   Delete the network namespace(s) and the bridge.
--help, -h      Help.
--logfilen=     If not given, defaults to /tmp/%s-{RANDOM_NUMBER}.
 -n=            The number of containers to create (defaults to one).
--ns=           The name of the net namespace to be created (defaults to netns).
--step=         Increase the value of the IP address by STEP (defaults to 1).
--verbose, -v   Verbose mode.\n" "$SCRIPTNAME"
}

if [ "$#" -gt 0 ]; then
    while [ "$#" -gt 0 ]; do
        OPT="$1"
        case "$OPT" in
            --cidr) shift; CIDR="$1" ;;
            --destroy|-d) DESTROY=1 ;;
            --help|-h) usage; exit 0 ;;
            --logfile) shift; LOGFILE="$1" ;;
            -n) shift; NUM="$1" ;;
            --ns) shift; NET_NS="$1" ;;
            --step) shift; STEP="$1" ;;
            --verbose|-v) set -x ;;
            *) printf "%b Unrecognized option %s\n" "$ERROR" "$OPT"; usage; exit 1 ;;
        esac
        shift
    done
fi

if [ -z "$LOGFILE" ]
then
    LOGFILE="/tmp/${SCRIPTNAME}-${RANDOM}"
fi

# This will write to both `stdout` and a log file.
# https://www.linuxjournal.com/content/bash-redirections-using-exec
exec 1> >(tee -a "$LOGFILE") 2>&1
#npipe=/tmp/$$.tmp
#trap "rm -f $npipe" EXIT
#mknod $npipe p
#tee <$npipe log &
#exec 1>&-
#exec 1>$npipe

NETWORK="${CIDR%/*}"
MASK="${CIDR##*/}"
# `%` deletes the shortest string to the right that matches.
# Should be something like "172.16.0.".
FIRST_THREE_DOTTED_QUADS="${NETWORK%.*}"
# `##` deletes the longest string to the left that matches.
# Should be something like "0".
LAST_DOTTED_QUAD="${NETWORK##*.}"

# Glue the bridge IP together, i.e. "172.16.0" + "1"
LAST_DOTTED_QUAD_PLUS_ONE=$(("$LAST_DOTTED_QUAD" + 1))
BRIDGE_IP="$FIRST_THREE_DOTTED_QUADS.$LAST_DOTTED_QUAD_PLUS_ONE"

cleanup_container() {
    sudo ip netns delete "$NET_NS$1"

    # List nat table rules.
    #sudo iptables -t nat -L -n -v --line-numbers

    # TODO: Is this the safest way to delete this rule?
    #sudo iptables -t nat -A POSTROUTING -s "$CONTAINER_IP/"$MASK" -o "$ETH0" -j MASQUERADE
    sudo iptables -t nat -D POSTROUTING "$1"

}

create_veth_pairs() {
    printf "%b Adding \`veth$1/ceth$1\` veth pair to \`%s\`.\n" "$INFO" "$BRIDGE"

    # Create veth pair and add one end to the bridge.
    sudo ip link add "veth$1" type veth peer name "ceth$1"
    sudo ip link set "veth$1" up
    sudo ip link set dev "veth$1" master "$BRIDGE"
}

create_ns() {
    printf "%b Moving device \`ceth$1\` into new net namespace \`$NET_NS$1\`.\n" "$INFO"

    # Create new net namespace and move ceth$1 device into it.
    # ( We want the end of the veth pair in the namespace to have the name `eth0` ).
    sudo ip netns add "$NET_NS$1"
    sudo ip link set "ceth$1" netns "$NET_NS$1"
}

setup_container() {
    local increment=$(("$LAST_DOTTED_QUAD_PLUS_ONE" + $1 * "$STEP"))
    local container_ip="$FIRST_THREE_DOTTED_QUADS.$increment"

    printf "%b Creating container with address \`%s/%s\` in \`%s%d\`.\n" "$INFO" "$container_ip" "$MASK" "$NET_NS" "$1"

    sudo ip netns exec "$NET_NS$1" ip address add "$container_ip"/"$MASK" dev "ceth$1"
    sudo ip netns exec "$NET_NS$1" ip link set "ceth$1" up
    sudo ip netns exec "$NET_NS$1" ip link set lo up # optional
    sudo ip netns exec "$NET_NS$1" ip route add default via "$BRIDGE_IP"

    sudo iptables -t nat -A POSTROUTING -s "$container_ip"/"$MASK" -o "$ETH0" -j MASQUERADE
}

if [ -n "$DESTROY" ]
then
    sudo ip link delete "$BRIDGE"

    echo 0 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null

    sudo iptables -D FORWARD -o "$ETH0" -i "$BRIDGE" -j ACCEPT
    sudo iptables -D FORWARD -i "$ETH0" -o "$BRIDGE" -j ACCEPT
    sudo iptables -t nat -D POSTROUTING 1

    sudo modprobe --remove br_netfilter

    for (( i = 1; i <= "$NUM"; i++ ))
    do
        #sudo ip link set dev veth1 nomaster
        cleanup_container "$i"
    done
else
    if ! ip link show "$BRIDGE" &> /dev/null
    then
        printf "%b Creating bridge device \`%s\` with address \`%s/%s\`.\n" "$INFO" "$BRIDGE" "$BRIDGE_IP" "$MASK"
        printf "%b \n" "$INFO"

        sudo ip link add name "$BRIDGE" type bridge
        sudo ip address add "$BRIDGE_IP"/"$MASK" dev "$BRIDGE"
        sudo ip link set "$BRIDGE" up

        sudo iptables -A FORWARD -o "$ETH0" -i "$BRIDGE" -j ACCEPT
        sudo iptables -A FORWARD -i "$ETH0" -o "$BRIDGE" -j ACCEPT

        # This tells the kernel not to chuck away a packet that's not destined for an
        # interface and instead to send it on.  It makes sense to disable it for an
        # individual workstation (because it usually doesn't need to perform the functions
        # of a router, but we now do need to turn this into a router.
        echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    fi

    printf "%b +++++++++++++++++++++\n" "$INFO"
    printf "%b Creating %d containers\n" "$INFO" "$NUM"
    printf "%b +++++++++++++++++++++\n" "$INFO"

    for (( i = 1; i <= "$NUM"; i++ ))
    do
        create_veth_pairs "$i"
        create_ns "$i"
        setup_container "$i"
        # Separate container information with a blank link.
        printf "%b \n" "$INFO"
    done

    printf "%b To teardown:\n" "$INFO"
    printf "%b ./veth_network.sh -d -n %d --ns %s\n" "$INFO" "$NUM" "$NET_NS"
    printf "%b \n" "$INFO"
    printf "%b Logs written to \`%s\`.\n" "$INFO" "$LOGFILE"
fi


#!/bin/bash

set -eo pipefail

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"

if [ $EUID -ne 0 ]; then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

if ! command -v ipcalc > /dev/null
then
    printf "%b \`ipcalc\` not found within PATH.\n" "$ERROR"
    exit 1
fi

BRIDGE=br0
CIDR=172.16.0.0/12
DESTROY=
GATEWAY_INTERFACE=$(ip r | grep default | awk '{print $5}')
NET_NS=netns
HOSTS=1
SCRIPTNAME=$(basename "$0")
STEP=1

cleanup_container() {
    printf "%b Deleting net namespace \`%s\`.\n" "$INFO" "$NET_NS$1"
    ip netns delete "$NET_NS$1"
    iptables -t nat -D POSTROUTING "$1"
}

create_bridge() {
    printf "%b Creating bridge device \`%s\` with address \`%s/%s\`.\n" "$INFO" "$BRIDGE" "$BRIDGE_IP" "$NETMASK"
    printf "%b \n" "$INFO"

    ip link add name "$BRIDGE" type bridge
    ip address add "$BRIDGE_IP/$NETMASK" dev "$BRIDGE"
    ip link set "$BRIDGE" up

    iptables -A FORWARD -o "$GATEWAY_INTERFACE" -i "$BRIDGE" -j ACCEPT
    iptables -A FORWARD -i "$GATEWAY_INTERFACE" -o "$BRIDGE" -j ACCEPT
}

create_namespace() {
    printf "%b Moving device \`ceth$1\` into new net namespace \`%s\`.\n" "$INFO" "$NET_NS$1"

    # Create new net namespace and move ceth$1 device into it.
    ip netns add "$NET_NS$1"
    ip link set "ceth$1" netns "$NET_NS$1"
}

create_veth_pairs() {
    printf "%b Adding \`veth$1/ceth$1\` veth pair to \`%s\`.\n" "$INFO" "$BRIDGE"

    # Create veth pair and add one end to the bridge.
    ip link add "veth$1" type veth peer name "ceth$1"
    ip link set "veth$1" up
    ip link set dev "veth$1" master "$BRIDGE"
}

setup_container() {
    local index="$1"
    local base_ip="${NETWORK%.*}"
    local last_octet="${NETWORK##*.}"
    local container_ip="$base_ip.$((last_octet + index + STEP))"

    printf "%b Creating container with address \`%s/%s\` in \`%s%d\`.\n" "$INFO" "$container_ip" "$NETMASK" "$NET_NS" "$index"

    ip netns exec "$NET_NS$1" ip address add "$container_ip/$NETMASK" dev "ceth$1"
    ip netns exec "$NET_NS$1" ip link set "ceth$1" up
    ip netns exec "$NET_NS$1" ip link set lo up # Optional.
    ip netns exec "$NET_NS$1" ip route add default via "$BRIDGE_IP"

    iptables -t nat -A POSTROUTING -s "$container_ip"/32 -o "$GATEWAY_INTERFACE" -j MASQUERADE
}

usage() {
    printf "Usage: $SCRIPTNAME OPTIONS

Args:
--cidr          Provide a CIDR address to be used by all of the interfaces (defaults to 172.16.0.1/12).
--destroy, -d   Delete the network namespace(s) and the bridge.
--help, -h      Help.
--hosts         The number of hosts to create (defaults to one).
--logfile       If not given, defaults to /tmp/%s-{RANDOM_NUMBER}.
--ns            The name of the net namespace to be created (defaults to netns).
--step          Increase the value of the IP address by STEP (defaults to 1).
--verbose, -v   Verbose mode.\n" "$SCRIPTNAME"
    exit "$1"
}

if [ "$#" -gt 0 ]; then
    while [ "$#" -gt 0 ]; do
        OPT="$1"
        case "$OPT" in
            --cidr) shift; CIDR="$1" ;;
            --destroy|-d) DESTROY=1 ;;
            --help|-h) usage 0 ;;
            --hosts) shift; HOSTS="$1" ;;
            --logfile) shift; LOGFILE="$1" ;;
            --ns) shift; NET_NS="$1" ;;
            --step) shift; STEP="$1" ;;
            --verbose|-v) set -x ;;
            *) printf "%b Unrecognized option %s\n" "$ERROR" "$OPT"; usage 1 ;;
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

while IFS= read -r line
do
    case "$line" in
        Network:*) NETWORK=$(printf "%s" "$line" | awk '{print $2}') ;;
        HostMin:*) BRIDGE_IP=$(printf "%s" "$line" | awk '{print $2}') ;;
    esac
done <<< "$(ipcalc "$CIDR")" # We'll know if the CIDR address is invalid if the vars are empty.

if [ -z "$NETWORK" ] || [ -z "$BRIDGE_IP" ]
then
    printf "%b \`%s\` is an invalid CIDR address.\n" "$ERROR" "$CIDR"
    usage 1
fi

NETMASK="${NETWORK#*/}"
# Because we're using `ipcalc`, this conditional should never be true since a valid CIDR address
# should always have a network prefix.  Doesn't hurt to keep it.
if [ -z "$NETMASK" ]
then
    printf "%b CIDR address does not contain a network prefix.\n" "$ERROR"
    usage 1
fi

if [ -n "$DESTROY" ]
then
    printf "%b +++++++++++++++++++++++\n" "$INFO"
    printf "%b Destroying %d containers\n" "$INFO" "$HOSTS"
    printf "%b +++++++++++++++++++++++\n" "$INFO"

    ip link delete "$BRIDGE"

    echo 0 | tee /proc/sys/net/ipv4/ip_forward > /dev/null

    iptables -D FORWARD -o "$GATEWAY_INTERFACE" -i "$BRIDGE" -j ACCEPT
    iptables -D FORWARD -i "$GATEWAY_INTERFACE" -o "$BRIDGE" -j ACCEPT

    modprobe --remove br_netfilter

    # Clean up in reverse order so the indices in iptables aren't constantly updated.
    for (( i = "$HOSTS"; i > 0; i-- ))
    do
        #ip link set dev veth1 nomaster
        cleanup_container "$i"
    done
else
    if ! ip link show "$BRIDGE" &> /dev/null
    then
        modprobe br_netfilter
        # This tells the kernel not to chuck away a packet that's not destined for an
        # interface and instead to send it on.  It makes sense to disable it for an
        # individual workstation (because it usually doesn't need to perform the functions
        # of a router, but we now do need to turn this into a router.
        echo 1 | tee /proc/sys/net/ipv4/ip_forward > /dev/null
        create_bridge
    fi

    printf "%b +++++++++++++++++++++\n" "$INFO"
    printf "%b Creating %d containers\n" "$INFO" "$HOSTS"
    printf "%b +++++++++++++++++++++\n" "$INFO"

    for (( i = 1; i <= "$HOSTS"; i++ ))
    do
        create_veth_pairs "$i"
        create_namespace "$i"
        setup_container "$i"
        # Separate container information with a blank link.
        printf "%b \n" "$INFO"
    done

    printf "%b To teardown:\n" "$INFO"
    printf "%b %s -d -n %d --ns %s\n" "$INFO" "$SCRIPTNAME" "$HOSTS" "$NET_NS"
    printf "%b \n" "$INFO"
    printf "%b Logs written to \`%s\`.\n" "$INFO" "$LOGFILE"
fi


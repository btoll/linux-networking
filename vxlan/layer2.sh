#!/bin/bash

# Everything created in this script is not accessible from the root namespace.
# The virtual bridge is created in the net namespace passed in as --ns,
# so to see that and the other net namespaces that are "plugged" into it
# one must `ip netns exec foo bash`.

# container namespaces                 container namespaces
# 10.0.0.10, 10.0.0.11                 10.0.0.12, 10.0.0.13
#        |                                      |
#      veth                                  veth
#        |                                      |
#    host0/br0                           host1/br0
#        |                                      |
#    vxlan100  =======================  vxlan100
#        |          UDP/4789                 |
#  host0 underlay                       host1 underlay
#  172.16.0.1                           172.16.0.2
#        \                                      /
#         \                                    /
#               root namespace bridge

# root ns
# - host-br0 bridge virtual interface (no IP)
# - host-veth0 plugged into host-br0 (no IP)
# - host-veth1 plugged into host-br0 (no IP)
#
# host0 ns
# - host-ceth0 connected to host-veth0 in root ns (underlay IP 172.16.0.1/16)
# - br0 virtual bridge interface (no IP)
# - veth0 plugged into br0 (no IP)
# - vxlan100 tunneled to vxlan100 in host1 ns (no IP)
#
# host1 ns
# - host-ceth1 connected to host-veth1 in root ns (underlay IP 172.16.0.2/16)
# - br0 virtual bridge interface (no IP)
# - veth1 plugged into br0 (no IP)
# - vxlan100 tunneled to vxlan100 in host0 ns (no IP)

set -eo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"
#YELLOW="\e[43m[INFO]\e[0m"

if [ $EUID -ne 0 ]; then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

trap cleanup ERR

cleanup() {
    local ns
    for ns in $(ip netns list | awk '/host[0-9]+(-container[0-9]+)?/ {print $1}')
    do
        ip netns delete "$ns"
    done
    ip link delete "host$BRIDGE" type bridge 2> /dev/null
}

create_host() {
    local index="$1"
    local hostns="host$index"
    local containerns

    local first_three_octets="${HOST_BRIDGE_IP%.*}"
    local last_octet="${HOST_BRIDGE_IP##*.}"

    # Create the host (i.e., the new net namespace which will include
    # the bridge and the veth pair.
    ip netns add "$hostns"

    # Each host gets its own bridge.
    ip -netns "$hostns" link add name "$BRIDGE" type bridge
    ip -netns "$hostns" link set "$BRIDGE" up

    # Yes, we're going to reuse these local vars.
    first_three_octets="${CONTAINER_NETWORK%.*}"
    last_octet="${CONTAINER_NETWORK##*.}"

    # Bring up loopback (optional).
    ip -netns "$hostns" link set lo up

    for ((n=0; n < CONTAINERS; n++))
    do

        # Create the veth pair.
        ip -netns "$hostns" link add "veth$n" type veth peer name "ceth$n"
        ip -netns "$hostns" link set "veth$n" up

        # Create new "container" net namespace and move one end of the veth pair into it.
        containerns="${hostns}-container$n"
        ip netns add "$containerns"
        ip -netns "$hostns" link set "ceth$n" netns "$containerns"

        # Attach the other end to the bridge device.
        ip -netns "$hostns" link set dev "veth$n" master "$BRIDGE"

        # Add IP address to endpoint that was moved into its own net namespace
        # (the "cable" plugged into the bridge does NOT get an IP address).
        ip -netns "$containerns" address add "$first_three_octets.$((last_octet + CONTAINER_COUNTER))/$CONTAINER_NETMASK" dev "ceth$n"
        ip -netns "$containerns" link set "ceth$n" up
        # Bring up loopback (optional).
        ip -netns "$containerns" link set lo up

        CONTAINER_COUNTER=$((CONTAINER_COUNTER + 1))
    done
}

create_root_bridge() {
    local first_three_octets="${HOST_BRIDGE_IP%.*}"
    local last_octet="${HOST_BRIDGE_IP##*.}"
    local i

    ip link add name "host$BRIDGE" type bridge
#    ip address add "$HOST_BRIDGE_IP/$HOST_NETMASK" dev "host$BRIDGE"

    for ((i=0; i < HOSTS; i++))
    do
        # Create veth pair.
        ip link add "host-veth$i" type veth peer name "host-ceth$i"
        # Move one end into host ns, add IP address and bring it up.
        ip link set "host-ceth$i" netns "host$i"
        ip -n "host$i" address add "$first_three_octets.$((last_octet + i))/$HOST_NETMASK" dev "host-ceth$i"
        ip -n "host$i" link set "host-ceth$i" up
        # Add other end to host bridge and bring it up.
        ip link set dev "host-veth$i" master "host$BRIDGE"
        ip link set "host-veth$i" up
    done

    ip link set "host$BRIDGE" up
}

setup_vxlan_vteps() {
    local vni=100
    local vtep="vxlan$vni"
    local index
    local local_ip
    local peer_index
    local peer_ip

    for ((index = 0; index < HOSTS; index++)); do
        local_ip="${HOST_BRIDGE_IP%.*}.$(( ${HOST_BRIDGE_IP##*.} + index ))"

        ip -netns "host$index" link add "$vtep" type vxlan \
            id "$vni" \
            local "$local_ip" \
            dev "host-ceth$index" \
            dstport 4789

        ip -netns "host$index" link set dev "$vtep" master "$BRIDGE"
        ip -netns "host$index" link set "$vtep" mtu 1450
        ip -netns "host$index" link set "$vtep" up

        for ((peer_index = 0; peer_index < HOSTS; peer_index++)); do
            [ "$peer_index" -eq "$index" ] && continue

            peer_ip="${HOST_BRIDGE_IP%.*}.$(( ${HOST_BRIDGE_IP##*.} + peer_index ))"

            ip netns exec "host$index" bridge fdb append \
                00:00:00:00:00:00 \
                dev "$vtep" \
                dst "$peer_ip" \
                self permanent
        done
    done
}

status() {
    local h=()
    local c=()
    local a
    local ns
    local v
    local line

    printf "%b net namespaces\n" "$INFO"
    # Remove the network namespace IDS, i.e., `host0 (id: 0)`.
    # This is safe b/c there cannot be a space in a network name.
    for ns in $(ip netns list | awk '{print $1}')
    do
        printf "%b \t\t%s\n" "$INFO" "$ns"
        if [[ "$ns" =~ - ]]
        then
            c+=("$ns")
        else
            h+=("$ns")
        fi
    done

    printf "%b \n" "$INFO"

    printf "%b root namespace\n" "$INFO"
    while read -r line
    do
        printf "%b \t\t%s\n" "$INFO" "$line"
    done < <(ip -br a)

    printf "%b \n" "$INFO"

    for a in h c
    do
        # Create a nameref (`current_array`) that points to the array name stored in `a`.
        declare -n current_array="$a"
        for v in "${current_array[@]}"
        do
            if [[ ! ( "$v" =~ - ) ]]
            then
                printf "%b %s - bridge fdb\n" "$INFO" "$v"
                while read -r line
                do
                    printf "%b \t\t%s\n" "$INFO" "$line"
                done < <(ip netns exec "$v" bridge fdb show br "$BRIDGE")

                printf "%b \n" "$INFO"

                printf "%b %s - vxlan fdb\n" "$INFO" "$v"
                while read -r line
                do
                    printf "%b \t\t%s\n" "$INFO" "$line"
                done < <(ip netns exec "$v" bridge fdb show dev vxlan100)

                printf "%b \n" "$INFO"
            fi

            printf "%b %s\n" "$INFO" "$v"
            while read -r line
            do
                printf "%b \t\t%s\n" "$INFO" "$line"
            done < <(ip -n "$v" -br a)
            printf "%b \n" "$INFO"
        done
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
    printf -- "--container-cidr  : The CIDR address for the containers (defaults to 10.0.0.0/16.\n"
    printf -- "--containers      : The containers within each host (defaults to 2).\n"
    printf -- "--destroy         : Teardown.\n"
    printf -- "--host-cidr       : The CIDR address for the hosts (defaults to 172.16.0.0/16.\n"
    printf -- "--hosts           : A host should be thought of as a node or VM (defaults to 2).\n"
    printf -- "                    Each host will get two containers (i.e., its own isolated net namespace).\n"
    printf -- "--status          : Prints the network topology.\n"
    printf -- "-h, --help        : Show usage.\n"
    exit "$1"
}

BRIDGE=br0
CONTAINER_CIDR=10.0.0.0/16
CONTAINER_COUNTER=10
CONTAINERS=2
HOST_CIDR=172.16.0.0/16
DESTROY=
HOSTS=2
STATUS=

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --container-cidr) shift; CONTAINER_CIDR=$1 ;;
        --containers) shift; CONTAINERS=$1 ;;
        --destroy) DESTROY=1 ;;
        --host-cidr) shift; HOST_CIDR=$1 ;;
        --hosts) shift; HOSTS=$1 ;;
        -h|--help) usage 0 ;;
        --status) STATUS=1 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ -n "$DESTROY" ]
then
    cleanup
elif [ -n "$STATUS" ]
then
    status
else
    # 172.18.0.0/20 - 4096 addresses
    # 172.18.0.0/21 - 2048 addresses
    # 172.18.8.0/21 - 2048 addresses

    while IFS= read -r line
    do
        case "$line" in
            Network:*) HOST_NETWORK=$(printf "%s" "$line" | awk '{print $2}') ;;
            HostMin:*) HOST_BRIDGE_IP=$(printf "%s" "$line" | awk '{print $2}') ;;
        esac
    done <<< "$(ipcalc "$HOST_CIDR")" # We'll know if the host CIDR address is invalid if the vars are empty.

    if [ -z "$HOST_NETWORK" ]
    then
        printf "%b \`%s\` is an invalid host CIDR address.\n" "$ERROR" "$HOST_CIDR"
        usage 1
    fi

    HOST_NETMASK="${HOST_NETWORK#*/}"
    # Because we're using `ipcalc`, this conditional should never be true since a valid host CIDR address
    # should always have a network prefix.  Doesn't hurt to keep it.
    if [ -z "$HOST_NETMASK" ]
    then
        printf "%b host CIDR address does not contain a network prefix.\n" "$ERROR"
        usage 1
    fi

    while IFS= read -r line
    do
        case "$line" in
            Network:*) CONTAINER_NETWORK=$(printf "%s" "$line" | awk '{print $2}') ;;
#            HostMin:*) CONTAINER_BRIDGE_IP=$(printf "%s" "$line" | awk '{print $2}') ;;
        esac
    done <<< "$(ipcalc "$CONTAINER_CIDR")" # We'll know if the container CIDR address is invalid if the vars are empty.

    if [ -z "$CONTAINER_NETWORK" ]
    then
        printf "%b \`%s\` is an invalid host CIDR address.\n" "$ERROR" "$HOST_CIDR"
        usage 1
    fi

    CONTAINER_NETMASK="${CONTAINER_NETWORK#*/}"
    # Because we're using `ipcalc`, this conditional should never be true since a valid host CIDR address
    # should always have a network prefix.  Doesn't hurt to keep it.
    if [ -z "$CONTAINER_NETMASK" ]
    then
        printf "%b host CIDR address does not contain a network prefix.\n" "$ERROR"
        usage 1
    fi

    for ((i=0; i < HOSTS; i++))
    do
        create_host $i
    done

    create_root_bridge
    setup_vxlan_vteps
fi


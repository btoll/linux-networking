# linux-networking

There is a scintillating article that accompanies this repository, [On Linux Container Networking].  Check it out.

## Bridge

The `bridge.sh` script will create new `net` namespaces and then enable communication between the `net` namespaces using a layer 2 bridge that created in the root `net` namespace.

- The new bridge virtual device will have an IP address in the network of the default network stack.
- A `veth` pair will be created for each host (`--host`).  One half of the pair will be moved to the new `net` namespace and given an IP address in the CIDR range (`--cidr`), and the other half will remain in the root namespace.  The `veth` in the root namespace will **not** be given an IP address, instead it will be add to the new virtual bridge (this can be visualized as plugging its half of the cable into a layer 2 network switch).
- All Internet traffic is `NAT`ed using `iptables MASQUERADE`.
- The script will generate routes that facilitate all traffic:
    + "Container" to "container" (between new `net` namespaces).
    + "Container" to Internet.
    + Host to subnet.

### Examples

Create three networked containers:

```bash
$ ./bridge.sh --hosts 3 --ns foo --cidr 172.18.0.0/12
```

Delete the three containers:

```bash
$ ./bridge.sh --destroy --hosts 3 --ns foo
```

Show all veth devices attached to a bridge:

```bash
$ ip link show master br0
```

Run a command in one of the new network namespaces:

```bash
$ sudo ip -n netns3 address
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
64: ceth3@if65: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 82:c5:a4:9b:04:4a brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.16.0.31/12 scope global ceth3
       valid_lft forever preferred_lft forever
    inet6 fe80::80c5:a4ff:fe9b:44a/64 scope link
       valid_lft forever preferred_lft forever
```

Or:

```bash
$ sudo ip netns exec netns3 ip address
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
64: ceth3@if65: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 82:c5:a4:9b:04:4a brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.16.0.31/12 scope global ceth3
       valid_lft forever preferred_lft forever
    inet6 fe80::80c5:a4ff:fe9b:44a/64 scope link
       valid_lft forever preferred_lft forever
```

Pick your poison.

> To get a shell inside the `netns3` net namespace:
>
> ```bash
> $ sudo ip netns exec netns3 bash
> ```

<!--
# If DNS doesn't work in the container process, try this:
#sudo mkdir -p /etc/netns/"$NET_NS"
#sudo touch /etc/netns/"$NET_NS"/resolv.conf
-->

## Subnetting

The `subnetting.sh` script will create new `net` namespaces and then enable communication between the `net` namespaces and the default network stack (in the root namespace) by giving both ends of the `veth` pair IP addresses.

- Each host (`--host`) will be given a subnet with a /24 mask.  The `veth` interface in the new `net` namespace will be given an addressable IP address in the subnet, and the `veth` interface in the root namespace will be given the routing IP address of the subnet, i.e. the gateway (for example, 172.16.2.1).
- All Internet traffic is `NAT`ed using `iptables MASQUERADE`.
- The script will generate routes that facilitate all traffic:
    + Subnet to subnet (between new `net` namespaces).
    + Subnet to Internet.
    + Host to subnet.

## Service Discovery

Using the `subnetting.sh` script to set up a network, let's implement basic service discovery using [`dnsmasq`].

Here is the basic idea:

- Run `dnsmasq` in one of the `net` namespaces.
- Execute a simple `bash` script that will do the following:
    + Accept a `net` namespace name as the sole argument.
    + Using the namespace name, lookup the IP address bound to the `veth` that was moved into the namespace.
    + Register it by writing a ".host" file to `/etc/dnsmasq.d/`.  `dnsmasq` will automatically notice it and create an A record.
    + Run the `hello` Go webserver (listening on port :8080).
    + When the script is killed, deregister the service by removing the host file that was added to `/etc/dnsmasq.d/`.  Again, `dnsmasq` will automatically notice the change and remove the A record.

Here is `/etc/dnsmasq.conf`:

```conf
hostsdir=/etc/dnsmasq.d/ # inotify watches the dir

no-resolv

server=1.1.1.1
server=8.8.8.8

listen-address=127.0.0.1

bind-interfaces
interface=ceth1

# Local domain configuration
local-service
local=/service.local/
expand-hosts

# This creates an A record for dnsmasq.  Put all others in /etc/dnsmasq.d/.
interface-name=dnsmasq.service.local,ceth1

# Create an SRV record for dnsmasq.  I don't think that others can be
# dynamically added.
# dig @172.16.2.2 +short SRV _dns._udp.dnsmasq.service.local
srv-host=_dns._udp.service.local,dnsmasq.service.local,53,10,50

```

Here is `hello.sh`:

```bash
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

```

Finally, the Go program:

```go
package main

import (
	"io"
	"log"
	"net/http"
)

func hello(w http.ResponseWriter, r *http.Request) {
	io.WriteString(w, "Hello!\n")
}

func main() {
	http.HandleFunc("/", hello)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
```

Create the network:

```bash
sudo bash subnetting.sh --hosts 3 --ns foo
```

The best way to see the example in action is to open four terminals (of course you're using a terminal multiplexer like `tmux`):

1. Run `ip netns exec foo1 dnsmasq -d --log-queries`.
1. Watch `/etc/dnsmasq.d/` to see the service registered and deregistered: `watch -n1 ls /etc/dnsmasq.d`.
1. Run `sudo bash hello.sh foo3`.
1. `curl` the web server:
    ```bash
    $ dig @172.16.1.2 A +short hello.local
    172.16.3.2
    $ curl http://172.16.3.2:8080
    Hello!
    ```

That's it.

## Saving and restoring the firewall rules (iptables)

```bash
$ sudo iptables-save > /tmp/iptables.backup
```

Sometime later...

```bash
$ sudo iptables-restore < /tmp/iptables.backup
```

## References

- [On Linux Container Networking]
- [Container Networking From Scratch](https://www.youtube.com/watch?v=6v_BDHIgOY8)
- [How Container Networking Works](https://iximiuz.com/en/posts/container-networking-is-simple/)
- [Network namespaces to the Internet with veth and NAT](https://josephmuia.ca/2018-05-16-net-namespaces-veth-nat/)
- [Bash Redirections Using Exec](https://www.linuxjournal.com/content/bash-redirections-using-exec)

## License

[GPLv3](COPYING)

## Author

Benjamin Toll

[On Linux Container Networking]: https://benjamintoll.com/2026/08/12/on-linux-container-networking/
[`dnsmasq`]: https://dnsmasq.org/doc.html


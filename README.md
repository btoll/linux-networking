# linux-networking

There is a scintillating article that accompanies this repository, [On Linux Container Networking](/2023/11/28/on-linux-container-networking/).  Check it out.

Note that no `iptables` rules are needed if not communicating with any other networks.  Pinging all `veth` interfaces attached to bridge `br0` and the main `eth0` interface will all work.

## Saving and restoring the firewall rules (iptables)

```bash
$ sudo iptables-save > /tmp/iptables.backup
```

Sometime later...

```bash
$ sudo iptables-restore < /tmp/iptables.backup
```

## Examples

Create three networked containers:

```bash
$ ./veth_network.sh -n 3 --ns foo --cidr 172.18.0.0/12
```

Delete the three containers:

```bash
$ ./veth_network.sh -d -n 3 --ns foo
```

Show all veth devices attached to a bridge:

```bash
$ ip link show master br0
```

Run a command in one of the new network namespaces:

```bash
$ sudo nsenter --net=/var/run/netns/netns3 ip address
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

> To get a shell inside the net namespace:
>
> ```bash
> $ sudo nsenter --net=/var/run/netns/netns3 bash
> ```
> Or:
> ```bash
> $ sudo ip netns exec netns3 bash
> ```

<!--
# If DNS doesn't work in the container process, try this:
#sudo mkdir -p /etc/netns/"$NET_NS"
#sudo touch /etc/netns/"$NET_NS"/resolv.conf
-->

## References

- [On Linux Container Networking](/2023/11/28/on-linux-container-networking/)
- [Container Networking From Scratch](https://www.youtube.com/watch?v=6v_BDHIgOY8)
- [How Container Networking Works](https://iximiuz.com/en/posts/container-networking-is-simple/)
- [Network namespaces to the Internet with veth and NAT](https://josephmuia.ca/2018-05-16-net-namespaces-veth-nat/)
- [Bash Redirections Using Exec](https://www.linuxjournal.com/content/bash-redirections-using-exec)

## License

[GPLv3](COPYING)

## Author

Benjamin Toll


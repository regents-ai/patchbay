#!/bin/sh
# Lets the picture-taker reach public websites and nothing else, then starts
# it as an ordinary user. Only DNS on Fly's resolver is let through to the
# private network; replies to Patchbay's requests go out as part of the
# connection Patchbay opened. The rules match the user in nftables itself,
# since Fly's kernel has no iptables owner match.
set -eu

nft -f - <<'RULES'
table inet shots {
  chain browser {
    ct state established,related accept
    ip6 daddr fdaa::3 udp dport 53 accept
    ip6 daddr fdaa::3 tcp dport 53 accept
    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4 } counter reject
    ip6 daddr { ::/128, ::1/128, ::ffff:0:0/96, 64:ff9b::/96, fc00::/7, fe80::/10, ff00::/8 } counter reject
  }

  # Only what the browser's user sends is checked; what the machine itself
  # sends, such as its IPv6 neighbour lookups, belongs to no user.
  chain out {
    type filter hook output priority 0; policy accept;
    meta skuid "node" jump browser
  }
}
RULES

exec setpriv --reuid=node --regid=node --init-groups --inh-caps=-all node server.js

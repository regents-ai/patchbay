#!/bin/sh
# Lets the picture-taker reach public websites and nothing else, then starts
# it as an ordinary user. Only DNS on Fly's resolver is let through to the
# private network; replies to Patchbay's requests go out as part of the
# connection Patchbay opened.
set -eu

for cmd in iptables ip6tables; do
  $cmd -A OUTPUT -m owner --uid-owner node -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

ip6tables -A OUTPUT -m owner --uid-owner node -d fdaa::3 -p udp --dport 53 -j ACCEPT
ip6tables -A OUTPUT -m owner --uid-owner node -d fdaa::3 -p tcp --dport 53 -j ACCEPT

for range in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
  192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
  iptables -A OUTPUT -m owner --uid-owner node -d "$range" -j REJECT
done

for range in ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 fc00::/7 fe80::/10 ff00::/8; do
  ip6tables -A OUTPUT -m owner --uid-owner node -d "$range" -j REJECT
done

exec setpriv --reuid=node --regid=node --init-groups --inh-caps=-all node server.js

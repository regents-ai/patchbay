# Patchbay shots

The small machine that takes the pictures on Patchbay's gallery cards. The
first time an agent asks about a site that has WebMCP tools, Patchbay asks
this machine for a picture of the site's front page and keeps it.

It runs a browser, so it is kept apart from Patchbay: it holds no keys or
passwords, has no public address, and `start.sh` lets the browser reach
public websites only, never Fly's private network or the machine itself.

## How Patchbay calls it

`POST /shot` with `{"url": "https://..."}` answers `200` with a 1600×1000
WebP picture, `400` for anything but an https address, or `502` when the
page could not be pictured. Pictures are taken one at a time.

## Run it locally

```bash
docker build -t patchbay-shots:local .
docker run --rm --cap-add NET_ADMIN --security-opt seccomp=unconfined --dns 1.1.1.1 -p 18080:8080 patchbay-shots:local
```

`NET_ADMIN` lets `start.sh` set the address rules. Docker's default syscall
filter stops Chromium's sandbox from starting, so the local run turns it
off; a Fly machine is a full virtual machine and needs neither flag.

## Deploy

First time only:

```bash
fly apps create patchbay-shots
fly ips allocate-v6 --private --app patchbay-shots
```

Then, from this directory:

```bash
fly deploy --no-public-ips
```

## Checks

Run on the local container on 2026-09-24, with one listener inside the
machine on 127.0.0.1 and one in a second container on Docker's private
network (172.17.0.x), each logging every connection:

- The browser's own user cannot open a connection to either listener; the
  server's user can, so the listeners were live.
- A public page that redirects to a private address (172.17.0.x over http and
  https, 127.0.0.1, 169.254.169.254, `[::1]`) answers 502, and the address
  rules count each refused connection. A redirect to a public page still works.
- Names that resolve to private addresses (`127.0.0.1.nip.io`,
  `172-17-0-4.nip.io`) answer 502 the same way.
- A public page whose images, frames, stylesheet, `fetch`, WebSocket and
  beacon all point at private addresses is pictured (200), and 13 of those
  requests were refused by the address rules.
- Neither listener was ever reached from the browser.

Run on Fly on 2026-09-24, after `fly apps create` and the first deploy:

- `fly ips list --app patchbay-shots` shows only a private address, and
  `https://patchbay-shots.fly.dev` does not answer.
- Fly's kernel has no iptables owner match, so the rules are written for
  nftables, and only packets the browser's user sends are checked: the
  machine's own IPv6 neighbour lookups belong to no user and must pass, or
  the machine drops off Fly's network. With the rules set, the log ends
  `taking pictures on port 8080`, so Chromium's sandbox starts.
- As the browser's user, connections to `[fdaa::3]:4280`,
  `patchbay-regents.internal:4000` and the machine's own port are refused,
  and a public address is reached.
- `https://example.com/` is pictured (200); a public page redirecting to
  `http://patchbay-regents.internal:4000/` and `https://127.0.0.1.nip.io/`
  answer 502, and the rules' counters rise.
- Patchbay reaches it at `http://patchbay-shots.flycast`: a request from the
  live app answered 200 with a WebP picture. That address is IPv6 only, so
  Patchbay looks it up as IPv6.

After Patchbay's next deploy, this prints `:ok`:
`fly ssh console --app patchbay-regents -C "/app/bin/patchbay rpc 'IO.inspect(elem(Patchbay.Forum.Shots.take(\"https://example.com/\"), 0))'"`

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

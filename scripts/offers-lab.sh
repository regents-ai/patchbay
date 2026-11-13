#!/usr/bin/env bash
# The agent offers lab: Patchbay's offer market on anvil, on this machine only.
#
#   scripts/offers-lab.sh start   # anvil as Base (chain 8453) on 127.0.0.1:58620,
#                                 # a fresh market, and its settings in the env file
#   scripts/offers-lab.sh stop    # stops that anvil, by the pid it recorded
#
# Then, in platform/:
#
#   source /tmp/patchbay-offers-lab/env
#   mix patchbay.offers place stripe.com        # a placement for a listed site
#   mix patchbay.offers accept <your wallet>    # Patchbay accepts an advertiser
#   mix patchbay.offers fund <your wallet>      # 1,000 lab USDC
#   mix phx.server                              # then open /offers
#
# Deploying needs no key: every transaction is sent from one of anvil's own
# unlocked accounts. The env file carries anvil's published test key for
# account 1, which signs Patchbay's admissions in the lab; it is never a real
# key. The deploy refuses any node that is not anvil serving chain 8453 on
# this machine (PatchbayDev.OffersLab).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lab_dir="/tmp/patchbay-offers-lab"
port=58620
rpc_url="http://127.0.0.1:${port}"
pid_file="${lab_dir}/anvil.pid"

running() {
  [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null
}

case "${1:-}" in
  start)
    mkdir -p "${lab_dir}"
    if running; then
      echo "The offers lab is already running (anvil pid $(cat "${pid_file}"))." >&2
      exit 1
    fi

    anvil --chain-id 8453 --host 127.0.0.1 --port "${port}" --silent >"${lab_dir}/anvil.log" 2>&1 &
    echo $! >"${pid_file}"

    for _ in $(seq 1 50); do
      if cast chain-id --rpc-url "${rpc_url}" >/dev/null 2>&1; then break; fi
      sleep 0.2
    done

    (cd "${root}/contracts" && forge build --quiet)
    (umask 077 && cd "${root}/platform" && mix patchbay.offers lab --rpc-url "${rpc_url}" --env-file "${lab_dir}/env")
    echo "Anvil pid $(cat "${pid_file}"). Settings: source ${lab_dir}/env"
    ;;

  stop)
    if running; then
      kill "$(cat "${pid_file}")"
      echo "Stopped anvil pid $(cat "${pid_file}")."
    else
      echo "The offers lab is not running."
    fi
    rm -f "${pid_file}"
    ;;

  *)
    echo "Usage: scripts/offers-lab.sh start|stop" >&2
    exit 2
    ;;
esac

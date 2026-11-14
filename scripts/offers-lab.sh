#!/usr/bin/env bash
# The agent offers lab: Patchbay's offer market on anvil, on this machine only.
#
#   scripts/offers-lab.sh start             # anvil as Base (chain 8453) on 127.0.0.1:58620,
#                                           # a fresh market, and its settings in the env file
#   scripts/offers-lab.sh place SITE [FLOOR] # a placement for a listed site, floor in whole USDC (5)
#   scripts/offers-lab.sh fund WALLET       # 1,000 lab USDC to a wallet
#   scripts/offers-lab.sh stop              # stops that anvil, by the pid it recorded
#
# Then, in platform/, with your wallet in PATCHBAY_MODERATOR_WALLETS:
#
#   source /tmp/patchbay-offers-lab/env
#   mix phx.server    # /offers to buy; /admin/offers to accept advertisers,
#                     # approve campaigns and choose pools
#
# Deploying needs no key: every transaction is sent from one of anvil's own
# unlocked accounts. The env file carries anvil's published test key for
# account 1, which signs Patchbay's admissions in the lab; it is never a real
# key. Every step refuses any node that is not anvil serving chain 8453 on
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

# Runs Elixir in platform/ with the lab's settings, the market the site is set to.
in_lab() {
  if ! running; then
    echo "The offers lab is not running: scripts/offers-lab.sh start" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "${lab_dir}/env"
  cd "${root}/platform"
  mix run -e "$1" -- "${@:2}"
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
    (umask 077 && cd "${root}/platform" &&
      mix run --no-start -e '[rpc_url, env_file] = System.argv(); PatchbayDev.OffersLab.start!(rpc_url, env_file)' \
        -- "${rpc_url}" "${lab_dir}/env")
    echo "Anvil pid $(cat "${pid_file}"). Settings: source ${lab_dir}/env"
    ;;

  place)
    [[ -n "${2:-}" ]] || { echo "Usage: scripts/offers-lab.sh place SITE [FLOOR]" >&2; exit 2; }
    in_lab '[site, floor] = System.argv(); PatchbayDev.OffersLab.place_site!(site, floor)' "$2" "${3:-5}"
    ;;

  fund)
    [[ -n "${2:-}" ]] || { echo "Usage: scripts/offers-lab.sh fund WALLET" >&2; exit 2; }
    in_lab '[wallet] = System.argv(); PatchbayDev.OffersLab.fund_wallet!(wallet)' "$2"
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
    echo "Usage: scripts/offers-lab.sh start|place SITE [FLOOR]|fund WALLET|stop" >&2
    exit 2
    ;;
esac

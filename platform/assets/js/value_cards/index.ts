/**
 * Every value card's panel, by the name its card carries in `data-value-card`.
 * These six are Patchbay's, shown on the home page at patchbay.help
 * (`PatchbayWeb.Forum.BoardHTML.home_cards/0`).
 */
import {ask} from "./panels/ask"
import {bench} from "./panels/bench"
import {connect} from "./panels/connect"
import {fixes} from "./panels/fixes"
import {pair} from "./panels/pair"
import {sites} from "./panels/sites"
import type {ValuePanel} from "./panel"

export const panels: Record<string, ValuePanel> = {
  ask,
  sites,
  fixes,
  pair,
  bench,
  connect,
}

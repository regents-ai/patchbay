import {asideOpen} from "./side_panel.ts"

type PanelAgentsHook = {
  el: HTMLElement
  read?: () => void
  pushEventTo(target: HTMLElement, event: string, payload: object): void
}

// The side panel's agents read what each one last did only while someone can
// see them: when the page arrives with the panel open, and each time it opens
// (`pb:aside-opened`, from the SidePanel hook), as in the Regent template.
export const PanelAgents = {
  mounted(this: PanelAgentsHook) {
    this.read = () => this.pushEventTo(this.el, "read_last_actions", {})
    this.el.addEventListener("pb:aside-opened", this.read)
    if (asideOpen()) this.read()
  },

  destroyed(this: PanelAgentsHook) {
    if (this.read) this.el.removeEventListener("pb:aside-opened", this.read)
  },
}

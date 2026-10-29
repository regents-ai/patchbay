type MenuAgentsHook = {
  el: HTMLElement
  menu?: HTMLElement | null
  read?: (event: Event) => void
  pushEventTo(target: HTMLElement, event: string, payload: object): void
}

// The account menu's agents read what each one last did only while someone can
// see them: each time the menu opens, and when it is already open as they arrive,
// as in the Regent template.
export const MenuAgents = {
  mounted(this: MenuAgentsHook) {
    this.menu = this.el.closest<HTMLElement>("[popover]")
    this.read = event => {
      if ((event as ToggleEvent).newState === "open")
        this.pushEventTo(this.el, "read_last_actions", {})
    }
    this.menu?.addEventListener("toggle", this.read)
    if (this.menu?.matches(":popover-open")) this.pushEventTo(this.el, "read_last_actions", {})
  },

  destroyed(this: MenuAgentsHook) {
    if (this.read) this.menu?.removeEventListener("toggle", this.read)
  },
}

import {mountProfile} from "../../vendor/regent_ui/profile.mjs"
import {profile} from "../shared_profile.ts"
import type {Hook} from "../hook_composition.ts"

type PublicNameHook = {
  el: HTMLElement
  pushEvent(event: string, payload: unknown): void
  stop?: () => void
}

// Saves the person's Public Display Name with their sign-in's own proof, then
// asks the page to read the name again so every place showing it shows the new
// one. As in ash-template.
export const PublicName: Hook = {
  mounted(this: PublicNameHook) {
    this.stop = mountProfile(this.el, {
      openProfile: () => profile,
      onSaved: () => this.pushEvent("public_name_saved", {}),
    })
  },

  destroyed(this: PublicNameHook) {
    this.stop?.()
  },
}

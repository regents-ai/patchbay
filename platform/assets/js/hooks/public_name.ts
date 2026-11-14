import {createProfileClient} from "../../vendor/regent_identity/profile_client.mjs"
import {mountProfile} from "../../vendor/regent_ui/profile.mjs"
import {browserCsrfToken} from "../privy/session.ts"
import type {Hook} from "../hook_composition.ts"

type PublicNameHook = {
  el: HTMLElement
  pushEvent(event: string, payload: unknown): void
  stop?: () => void
}

// Saves the person's Public Display Name with the page's own sign-in, its
// session cookie and forms token, then asks the page to read the name again so
// every place showing it shows the new one. Each save keeps the forms token of
// the press of Save: a switch of account renews the session and its token, so a
// save pressed before one changes nothing after it. As in ash-template.
export const PublicName: Hook = {
  mounted(this: PublicNameHook) {
    this.stop = mountProfile(this.el, {
      openProfile: () => {
        const token = browserCsrfToken()
        return createProfileClient({csrfToken: () => token})
      },
      onSaved: () => this.pushEvent("public_name_saved", {}),
    })
  },

  destroyed(this: PublicNameHook) {
    this.stop?.()
  },
}

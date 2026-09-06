import {loadProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import {mountProfile} from "../vendor/regent_ui/profile.mjs"
import {installProfileTools} from "../vendor/regent_identity/profile_tools.mjs"
import {loadPrivyBridge, privyAppId, requestAccountAction} from "./privy/account.js"

export function installSharedProfile() {
  const appId = privyAppId(document)
  const bridge = async () => {
    if (!appId) throw new Error("profile_unconfigured")
    const loaded = await loadPrivyBridge(document)
    if (!loaded) throw new Error("profile_unavailable")
    return loaded
  }
  const profile = (...args) => loadProfileAction(async () => {
    const loaded = await bridge()
    return (...args) => loaded.profile(appId, ...args)
  }, ...args)
  installProfileTools(profile)
  const root = document.querySelector("[data-regent-profile]")
  if (!root) return
  mountProfile(root, {
    profile,
    signIn: () => requestAccountAction("sign-in", document, {
      csrfToken: document.querySelector("meta[name=csrf-token]")?.content ?? "",
    }),
    async linkX() {
      const loaded = await bridge()
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => finish(false), 120_000)
        const changed = event => finish(event.detail?.ok === true)
        const finish = ok => {
          clearTimeout(timeout)
          window.removeEventListener("regent:profile-link", changed)
          if (ok) resolve()
          else reject(new Error("profile_link_failed"))
        }
        window.addEventListener("regent:profile-link", changed)
        void loaded.linkProfileX(appId).catch(() => finish(false))
      })
    },
    onIdentityChange(callback) {
      window.addEventListener("regent:profile-identity", callback)
      window.addEventListener("regent:profile-link", callback)
      return () => {
        window.removeEventListener("regent:profile-identity", callback)
        window.removeEventListener("regent:profile-link", callback)
      }
    },
  })
}

import {loadProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import {installProfileTools} from "../vendor/regent_identity/profile_tools.mjs"
import {loadPrivyBridge, privyAppId} from "./privy/account.ts"

// One change to the person's shared profile, answered through the sign-in bridge
// with the sign-in's own proof. It opens as it is asked for, so it belongs to
// whoever is signed in then, and every call of it uses that one client. The
// bridge loads only when a change is first opened. As in ash-template.
export function openProfile(documentRoot: Document = document): ProfileAction {
  const opening = (async () => {
    const appId = privyAppId(documentRoot)
    if (!appId) throw new Error("profile_unconfigured")
    const loaded = await loadPrivyBridge(documentRoot)
    if (!loaded) throw new Error("profile_unavailable")
    return loaded.openProfile(appId)
  })()
  // A change that is never used still settles quietly; each use reports its own failure.
  opening.catch(() => {})
  return (...args) => loadProfileAction(() => opening, ...args)
}

// Each agent tool call is its own change.
export function installSharedProfile() {
  installProfileTools((...args) => openProfile(document)(...args))
}

import {loadProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import {installProfileTools} from "../vendor/regent_identity/profile_tools.mjs"
import {loadPrivyBridge, privyAppId} from "./privy/account.ts"

// The person's shared profile, read and saved through the sign-in bridge with
// the sign-in's own proof. The bridge loads only when the profile is first used.
export const profile: ProfileAction = (...args) => loadProfileAction(async () => {
  const appId = privyAppId(document)
  if (!appId) throw new Error("profile_unconfigured")
  const loaded = await loadPrivyBridge(document)
  if (!loaded) throw new Error("profile_unavailable")
  return (...args) => loaded.profile(appId, ...args)
}, ...args)

export function installSharedProfile() {
  installProfileTools(profile)
}

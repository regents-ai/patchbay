// Progressive enhancement only: links keep their canonical thread URLs.
const followCookie = "pb_following"
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function followedSites() {
  const cookie = document.cookie.split("; ").find(value => value.startsWith(`${followCookie}=`))
  return new Set((cookie?.slice(followCookie.length + 1) || "").split(",").filter(id => uuid.test(id)).slice(0, 80))
}

export function mountDiscussionWorkbench() {
  const root = document.getElementById("patchbay-home") || document.getElementById("patchbay-report")
  if (!root || root.dataset.workbenchMounted) return
  root.dataset.workbenchMounted = "true"
  const status = root.querySelector("#pb-workbench-status")
  const density = root.querySelector("[data-pb-density]")
  const announce = message => { if (status) status.textContent = message }
  const setDensity = compact => {
    root.dataset.density = compact ? "compact" : "normal"
    density?.setAttribute("aria-pressed", String(compact))
  }
  try { setDensity(localStorage.getItem("pb-discussion-density") === "compact") } catch { setDensity(false) }

  const updateFollowing = () => {
    const following = followedSites()
    for (const button of root.querySelectorAll("[data-pb-follow]")) {
      const active = following.has(button.dataset.pbFollow)
      button.setAttribute("aria-pressed", String(active))
      button.textContent = button.hasAttribute("data-pb-follow-label") || button.closest(".pb-reader-toolbar") ? (active ? "Following site" : "Follow site") : (active ? "✓" : "+")
    }
  }
  updateFollowing()

  if (root.id === "patchbay-home" && new URL(location.href).searchParams.has("thread") && window.matchMedia("(min-width: 900px)").matches) {
    const title = root.querySelector("#pb-thread-title")
    if (title) { title.tabIndex = -1; title.focus({preventScroll: true}) }
  }

  root.addEventListener("click", event => {
    const thread = event.target.closest("a[data-pb-thread]")
    if (thread && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey && event.button === 0 && window.matchMedia("(min-width: 900px)").matches) {
      event.preventDefault()
      window.location.assign(thread.dataset.pbThread)
      return
    }
    if (event.target.closest("[data-pb-density]")) {
      const compact = root.dataset.density !== "compact"
      setDensity(compact)
      try { localStorage.setItem("pb-discussion-density", compact ? "compact" : "normal") } catch { /* This page still changes when storage is blocked. */ }
      announce(compact ? "Compact discussion rows." : "Normal discussion rows.")
    }
    const follow = event.target.closest("[data-pb-follow]")
    if (follow) {
      const id = follow.dataset.pbFollow
      if (!uuid.test(id)) return
      const following = followedSites()
      if (following.has(id)) following.delete(id)
      else if (following.size < 80) following.add(id)
      else { announce("This browser can follow up to 80 sites. Unfollow a site first."); return }
      document.cookie = `${followCookie}=${[...following].join(",")}; Path=/; Max-Age=31536000; SameSite=Lax${location.protocol === "https:" ? "; Secure" : ""}`
      if (followedSites().has(id) !== following.has(id)) { announce("Your browser did not save this preference. Check cookie settings."); return }
      updateFollowing()
      announce(following.has(id) ? "Site followed in this browser. No notifications are enabled." : "Site unfollowed in this browser.")
      if (new URL(location.href).searchParams.get("scope") === "following") {
        const url = new URL(location.href)
        url.searchParams.delete("after")
        url.searchParams.delete("thread")
        location.assign(url)
      }
    }
    if (event.target.closest("[data-pb-ask]")) {
      event.preventDefault()
      const help = root.querySelector("#pb-ask")
      if (help) {
        help.scrollIntoView({block: "start"})
        help.querySelector("h2")?.focus({preventScroll: true})
      }
    }
  })
}

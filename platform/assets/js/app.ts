import "../css/app.css"
import "./theme.ts"
import "../vendor/regent_ui/blog.mjs"
import "../vendor/regent_ui/discussion.mjs"
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/patchbay"
import {PatchbayWebMCP} from "./webmcp/room_hook.ts"
import {PatchbayRelativeTime} from "./hooks/relative_time.ts"
import {MotionList} from "./hooks/motion/moments.ts"
import {mountMotion} from "./motion.ts"
import {mountForumTools} from "./webmcp/forum_lifecycle.ts"
import {signedInProfileId} from "./webmcp/profile.ts"
import {installAccountControl} from "./privy/account.ts"
import {installSharedProfile} from "./shared_profile.ts"
import {mountDiscussionWorkbench} from "./discussion_workbench.ts"
import {mountHelloStream} from "./hello_stream.ts"
import {mountHeroForm} from "./hero_form.ts"
import {mountDiscussionSearch} from "./discussion_search.ts"
import {mountCardTopUp} from "./card_topup.ts"
import {mountAgentFunding, mountAgentSetup, mountReadinessCard} from "./webmcp/agent_setup.ts"
import {installCopyButtons} from "./copy_buttons.ts"
import topbar from "../vendor/topbar.js"

const csrfToken = document.querySelector("meta[name='csrf-token']")!.getAttribute("content")!
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    PatchbayWebMCP,
    PatchbayRelativeTime,
    MotionList,
  },
})

// Show progress bar on live navigation and form submits, in Patchbay's own
// accent rather than the generator's blue, so the bar belongs to the page.
const accent = getComputedStyle(document.documentElement).getPropertyValue("--pb-accent").trim()
topbar.config({barColors: {0: accent}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// One listener serves every copy button on every page, live or not.
installCopyButtons()

// The account strip, the report board tools and the standard motion all
// belong to every Patchbay page rather than to the room, so they are set up
// here. The tools are handed the profile the page is signed in as, so one that
// charges for an answer knows who to charge.
const offerPageWideSurfaces = () => {
  mountMotion(document)
  installAccountControl({fetch: window.fetch.bind(window), csrfToken})
  installSharedProfile()
  mountAgentSetup()
  mountReadinessCard()
  mountHelloStream()
  mountHeroForm({fetch: window.fetch.bind(window), csrfToken})
  mountDiscussionSearch()
  mountAgentFunding()
  mountCardTopUp()
  hideBrokenSiteLogos()
  mountDiscussionWorkbench()

  const rail = document.getElementById("pb-agent-setup") ?? document.getElementById("pb-readiness")
  mountForumTools(window, {
    fetch: window.fetch.bind(window),
    csrfToken,
    profileId: signedInProfileId(),
    paymentsEnabled: rail ? rail.getAttribute("data-payments-enabled") === "true" : undefined,
  })
}

const hideBrokenSiteLogos = () => {
  for (const img of document.querySelectorAll<HTMLImageElement>(".pb-site-logo")) {
    if (img.complete && img.naturalWidth === 0) img.hidden = true
    else img.addEventListener("error", () => { img.hidden = true }, {once: true})
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", offerPageWideSurfaces, {once: true})
} else {
  offerPageWideSurfaces()
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
// The part of phoenix_live_reload's reloader these tools use.
type LiveReloader = {
  enableServerLogs(): void
  openEditorAtCaller(target: EventTarget | null): void
  openEditorAtDef(target: EventTarget | null): void
}

declare global {
  interface Window {
    liveSocket: LiveSocket
    liveReloader: LiveReloader
  }
}

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", event => {
    const reloader = (event as CustomEvent<LiveReloader>).detail
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown: string | null = null
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

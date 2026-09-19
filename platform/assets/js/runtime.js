// The deck: arrows and the keyboard move between slides, the address keeps
// the place (#3 is the third slide), and the next slide is fetched early.
const deck = document.getElementById("patchbay-deck")
const slides = [...deck.querySelectorAll(".pb-deck-slide")]
const current = deck.querySelector("[data-deck-current]")

const fromHash = () => {
  const n = Number.parseInt(location.hash.slice(1), 10)
  return Number.isInteger(n) && n >= 1 && n <= slides.length ? n - 1 : 0
}

const show = (index) => {
  const at = (index + slides.length) % slides.length
  slides.forEach((slide, i) => (slide.hidden = i !== at))
  current.textContent = String(at + 1)
  history.replaceState(null, "", `#${at + 1}`)
  const next = slides[(at + 1) % slides.length]?.querySelector("img")
  if (next && !next.complete) next.loading = "eager"
  return at
}

if (slides.length > 0) {
  let at = show(fromHash())
  deck.querySelector("[data-deck-back]").addEventListener("click", () => (at = show(at - 1)))
  deck.querySelector("[data-deck-next]").addEventListener("click", () => (at = show(at + 1)))
  addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight" || event.key === "PageDown" || event.key === " ") at = show(at + 1)
    else if (event.key === "ArrowLeft" || event.key === "PageUp") at = show(at - 1)
    else if (event.key === "Home") at = show(0)
    else if (event.key === "End") at = show(slides.length - 1)
    else if (event.key === "f" && document.fullscreenEnabled) document.documentElement.requestFullscreen()
    else return
    event.preventDefault()
  })
  addEventListener("hashchange", () => (at = show(fromHash())))
}

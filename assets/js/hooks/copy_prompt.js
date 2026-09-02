/**
 * Copy one of the room's agent prompts. The clipboard is not available on every
 * browser or every connection, so when writing fails the prompt itself is
 * selected instead and the button says so, rather than claiming a copy that
 * never happened.
 */
export function copyPrompt(button, {document: doc = document, navigator: nav = navigator} = {}) {
  const target = doc.getElementById(button.dataset.copyTarget)
  if (!target) return Promise.resolve("missing")

  const text = typeof target.value === "string" ? target.value : target.textContent || ""
  const clipboard = nav && nav.clipboard

  if (!clipboard || typeof clipboard.writeText !== "function") {
    return Promise.resolve(selectAll(target))
  }

  return clipboard.writeText(text).then(() => "copied", () => selectAll(target))
}

function selectAll(target) {
  if (typeof target.focus === "function") target.focus()
  if (typeof target.select === "function") target.select()
  return "selected"
}

const WORDS = {copied: "Copied", selected: "Selected", missing: "Copy"}

export const PatchbayCopy = {
  mounted() {
    this.idle = this.el.textContent
    this.onClick = () => this.run()
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    clearTimeout(this.timer)
  },

  run() {
    copyPrompt(this.el).then(outcome => {
      this.el.textContent = WORDS[outcome] || this.idle
      this.el.dataset.state = outcome === "missing" ? "idle" : "done"
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        this.el.textContent = this.idle
        this.el.dataset.state = "idle"
      }, 1600)
    })
  },
}

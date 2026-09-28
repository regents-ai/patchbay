import type {SiteTool} from "./site_check.ts"

export const MOST_PICKED = 5

/**
 * The site's WebMCP tools under the form at the top of the home page, A to Z, once Patchbay has
 * found them: a row is picked or unpicked with a press, a picked row is
 * coloured, and the count beside the heading says how many of the five are
 * taken. Picks survive a new list for the tools still on it; the first list
 * takes the picks the page was given back.
 */
export function mountToolPicker(form: HTMLFormElement) {
  const box = form.querySelector<HTMLFieldSetElement>("#pb-fix-tools")
  const list = form.querySelector<HTMLUListElement>("#pb-fix-tools-list")
  const count = form.querySelector<HTMLElement>("#pb-fix-tools-count")
  if (!box || !list || !count) return null

  let picked = new Set((box.dataset.pbPicked ?? "").split("\n").filter(name => name !== ""))

  const boxes = () => Array.from(list.querySelectorAll<HTMLInputElement>("input[type=checkbox]"))

  const tally = () => {
    const taken = boxes().filter(input => input.checked)
    picked = new Set(taken.map(input => input.value))
    count.textContent = `${taken.length}/${MOST_PICKED}`
    for (const input of boxes()) {
      input.disabled = !input.checked && taken.length >= MOST_PICKED
      input.closest("li")!.toggleAttribute("data-pb-picked", input.checked)
    }
  }

  // An address without tools empties the list but keeps the picks, for when
  // the person goes back to the site they were picked from.
  const show = (tools: SiteTool[]) => {
    if (tools.length === 0) {
      list.replaceChildren()
      box.hidden = true
      return
    }
    list.replaceChildren(...tools.map(tool => row(tool, picked.has(tool.name))))
    box.hidden = false
    tally()
  }

  list.addEventListener("change", tally)
  return {show}
}

function row(tool: SiteTool, checked: boolean) {
  const item = document.createElement("li")
  const label = document.createElement("label")
  const input = document.createElement("input")
  input.type = "checkbox"
  input.name = "ask[tools][]"
  input.value = tool.name
  input.checked = checked
  const name = document.createElement("code")
  name.textContent = tool.name
  const about = document.createElement("span")
  about.textContent = tool.description
  about.title = tool.description
  label.append(input, name, about)
  item.append(label)
  return item
}

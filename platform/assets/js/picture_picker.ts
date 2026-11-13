import {deny} from "./hooks/motion/press.ts"

const TYPES = new Set(["image/png", "image/jpeg", "image/webp"])
const MEGABYTE = 1024 * 1024
let made = 0

/**
 * The post form's pictures, up to the post's limit: added with Add pictures,
 * or dropped on it, and shown small, each with its own Remove. The form's
 * file field holds exactly the pictures shown, in their order, so the post
 * carries them as shown. A picture that cannot go, of another kind, too
 * large or past the limit, is not added, and the line under the button says
 * so in plain words; at the limit the button says it is full.
 */
export function mountPicturePicker(form: HTMLFormElement) {
  const box = form.querySelector<HTMLFieldSetElement>("#pb-hero-pictures-box")
  if (!box) return
  const part = <T extends Element>(selector: string) => box.querySelector<T>(selector)!
  const field = part<HTMLInputElement>("#pb-hero-pictures")
  const chooser = part<HTMLInputElement>("[data-pb-pictures-chooser]")
  const add = part<HTMLButtonElement>("[data-pb-pictures-add]")
  const drop = part<HTMLElement>("[data-pb-pictures-drop]")
  const list = part<HTMLUListElement>("[data-pb-pictures-list]")
  const count = part<HTMLElement>("[data-pb-pictures-count]")
  const line = part<HTMLElement>("#pb-hero-pictures-errors")
  const template = part<HTMLTemplateElement>("template[data-pb-picture]")
  const most = Number(box.dataset.pbMost)
  const largest = Number(box.dataset.pbBytes)
  const full = `Up to ${most} pictures. Remove one to add another.`
  const shown: {file: File; item: HTMLLIElement}[] = []

  const say = (words: string) => {
    const said = form.ownerDocument.createElement("p")
    said.textContent = words
    line.replaceChildren(...(words === "" ? [] : [said]))
  }

  // The field takes the pictures shown; a change to them takes away a
  // preview of the post, as any change does (hero_form.ts).
  const settle = () => {
    const kept = new DataTransfer()
    for (const {file} of shown) kept.items.add(file)
    field.files = kept.files
    field.dispatchEvent(new Event("change", {bubbles: true}))
    count.textContent = `${shown.length}/${most}`
    add.setAttribute("aria-disabled", String(shown.length >= most))
  }

  const take = (files: File[]) => {
    const fitting = files.filter(file => TYPES.has(file.type) && file.size <= largest)
    const room = most - shown.length
    for (const file of fitting.slice(0, room)) {
      const item = picture(file)
      shown.push({file, item})
      list.append(item)
    }
    say([
      files.some(file => !TYPES.has(file.type)) ? "Pictures can be PNG, JPEG or WebP." : "",
      files.some(file => TYPES.has(file.type) && file.size > largest) ? `Each picture can be up to ${largest / MEGABYTE} MB.` : "",
      fitting.length > room ? `Up to ${most} pictures. The first ${most} are kept.` : "",
    ].filter(words => words !== "").join(" "))
    settle()
  }

  // Taking one away frees its place; the focus goes to the next Remove, or
  // the one before, or Add pictures when none is left.
  const remove = (item: HTMLLIElement) => {
    const at = shown.findIndex(entry => entry.item === item)
    shown.splice(at, 1)
    URL.revokeObjectURL(item.querySelector("img")!.src)
    item.remove()
    say("")
    settle()
    const next = shown[at] ?? shown[at - 1]
    ;(next ? next.item.querySelector("button")! : add).focus()
  }

  // A picture is named by its file's name, which its Remove is described by.
  const picture = (file: File) => {
    const item = template.content.firstElementChild!.cloneNode(true) as HTMLLIElement
    const image = item.querySelector("img")!
    image.src = URL.createObjectURL(file)
    image.alt = file.name
    image.id = `pb-hero-picture-${(made += 1)}`
    const button = item.querySelector("button")!
    button.setAttribute("aria-describedby", image.id)
    button.addEventListener("click", () => remove(item))
    return item
  }

  const refuseFull = () => {
    say(full)
    deny(add)
  }

  add.addEventListener("click", () => {
    if (shown.length >= most) refuseFull()
    else chooser.click()
  })
  chooser.addEventListener("change", () => {
    take(Array.from(chooser.files ?? []))
    chooser.value = ""
  })

  drop.addEventListener("dragover", event => {
    if (!event.dataTransfer?.types.includes("Files")) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    drop.dataset.pbDragging = ""
  })
  drop.addEventListener("dragleave", event => {
    if (!drop.contains(event.relatedTarget as Node | null)) delete drop.dataset.pbDragging
  })
  drop.addEventListener("drop", event => {
    event.preventDefault()
    delete drop.dataset.pbDragging
    if (shown.length >= most) refuseFull()
    else take(Array.from(event.dataTransfer?.files ?? []))
  })
}

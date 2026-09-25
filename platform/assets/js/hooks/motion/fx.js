/**
 * Sparks, rings and stitches are drawn in `#pb-motion-fx`, a layer over the
 * page that the page never patches and that no press can land on. Each bit
 * carries the id of the island that drew it, so an island that goes away
 * takes its bits with it.
 */
import {SPARK_COLORS} from "./shared.js"

const layer = () => document.getElementById("pb-motion-fx")

export function spawn(owner, count, className, x, y) {
  return Array.from({length: count}, (_, i) => {
    const bit = document.createElement("span")
    bit.className = className
    bit.dataset.fxOwner = owner.id
    bit.style.left = `${x}px`
    bit.style.top = `${y}px`
    bit.style.setProperty("--pb-fx-color", SPARK_COLORS[i % SPARK_COLORS.length])
    layer().append(bit)
    return bit
  })
}

export const sweep = bits => () => {
  for (const bit of bits) bit.remove()
}

export function sweepAll(owner) {
  sweep(layer().querySelectorAll(`[data-fx-owner="${owner.id}"]`))()
}

// The middle of an element, in the layer's coordinates.
export function centre(el) {
  const box = el.getBoundingClientRect()
  return [box.left + box.width / 2, box.top + box.height / 2]
}

// Loaded on demand from the homepage. WebGPU stays out of app.js.
// Adapted from TechTree's crown island (Vercel vgpu prism). See THIRD_PARTY_NOTICES.md.

import {createPrismRenderer} from "./optics/crown"

window.PatchbayOptics = window.PatchbayOptics || {}
window.PatchbayOptics.crown = createPrismRenderer

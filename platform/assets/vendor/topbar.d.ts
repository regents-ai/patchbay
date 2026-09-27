// The part of topbar 3.0.0 (topbar.js beside this file) that Patchbay uses.
declare const topbar: {
  config(options: {barColors?: Record<number, string>; shadowColor?: string}): void
  show(delay?: number): void
  hide(): void
}

export default topbar

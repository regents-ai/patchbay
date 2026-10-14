type SearchDialogHook = {
  el: HTMLDialogElement
  pushEvent(event: string, payload: object): void
  cleanup?: () => void
  sync?: () => void
}

// ash-template d5fe886 shell_panels.ts search behavior, attached to this
// isolated LiveView rather than the template's full application shell.
export const SearchDialog = {
  mounted(this: SearchDialogHook) {
    const dialog = this.el
    const searchInput = () => dialog.querySelector<HTMLInputElement>("#shell-search-input")
    const results = () => [...dialog.querySelectorAll<HTMLAnchorElement>("[data-search-result]")]
    const highlighted = () => results().find(result => result.getAttribute("aria-selected") === "true")
    const drawnQuery = () => dialog.querySelector<HTMLElement>("#shell-search-results")?.dataset.query
    let highlightedQuery: string | undefined
    let opener: Element | null = null
    const highlight = (result: HTMLAnchorElement | undefined) => {
      results().forEach(other => other.setAttribute("aria-selected", String(other === result)))
      if (result) {
        searchInput()?.setAttribute("aria-activedescendant", result.id)
        result.scrollIntoView({block: "nearest"})
      } else {
        searchInput()?.removeAttribute("aria-activedescendant")
      }
    }
    const syncSearch = () => {
      if (!dialog.open) return
      const query = drawnQuery()
      if (query !== highlightedQuery || !highlighted()) highlight(results()[0])
      highlightedQuery = query
    }
    const moveHighlight = (step: number) => {
      const all = results()
      if (all.length === 0) return
      const at = all.indexOf(highlighted() as HTMLAnchorElement)
      const next = at < 0 ? (step > 0 ? 0 : all.length - 1) : (at + step + all.length) % all.length
      highlight(all[next])
    }
    const openSearch = () => {
      if (dialog.open) return
      opener = document.activeElement
      dialog.showModal()
      searchInput()?.select()
      highlightedQuery = undefined
      syncSearch()
      this.pushEvent("open", {})
    }
    const closeSearch = () => dialog.close()
    const onDocumentClick = (event: MouseEvent) => {
      const target = event.target instanceof Element ? event.target : null
      if (target?.closest("#shell-search-button")) openSearch()
    }
    const onClick = (event: MouseEvent) => {
      const target = event.target instanceof Element ? event.target : null
      if (!target) return
      if (target.closest("[data-search-close], [data-search-result]")) return closeSearch()
      if (target === dialog) {
        const box = dialog.getBoundingClientRect()
        if (event.clientX < box.left || event.clientX > box.right ||
            event.clientY < box.top || event.clientY > box.bottom) closeSearch()
      }
    }
    const onKeydown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        openSearch()
        return
      }
      if (dialog.open && event.target === searchInput()) {
        if (event.key === "Escape") {
          event.preventDefault()
          closeSearch()
          return
        }
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault()
          moveHighlight(event.key === "ArrowDown" ? 1 : -1)
          return
        }
        const current = drawnQuery() === searchInput()?.value.trim()
        if (event.key === "Enter" && !event.isComposing && current && highlighted()) {
          event.preventDefault()
          highlighted()?.click()
        }
      }
    }
    const onPointerMove = (event: PointerEvent) => {
      const target = event.target instanceof Element ? event.target : null
      const result = target?.closest<HTMLAnchorElement>("[data-search-result]")
      if (result && result !== highlighted()) highlight(result)
    }
    const onClose = () => {
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus({preventScroll: true})
    }
    const keys = document.querySelector<HTMLElement>("[data-shell-search-keys]")
    if (keys && /Mac|iPhone|iPad/.test(navigator.platform)) keys.textContent = "⌘K"
    document.addEventListener("click", onDocumentClick)
    document.addEventListener("keydown", onKeydown)
    dialog.addEventListener("click", onClick)
    dialog.addEventListener("pointermove", onPointerMove)
    dialog.addEventListener("close", onClose)
    this.sync = syncSearch
    this.cleanup = () => {
      document.removeEventListener("click", onDocumentClick)
      document.removeEventListener("keydown", onKeydown)
      dialog.removeEventListener("click", onClick)
      dialog.removeEventListener("pointermove", onPointerMove)
      dialog.removeEventListener("close", onClose)
      if (dialog.open) closeSearch()
    }
  },
  updated(this: SearchDialogHook) { this.sync?.() },
  destroyed(this: SearchDialogHook) { this.cleanup?.() },
}

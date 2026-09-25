defmodule PatchbayWeb.Forum.EvidencePanel do
  @moduledoc """
  The tool page's evidence panel: the four levels of
  `PatchbayWeb.Forum.ToolEvidence`, one row each, a level the records hold
  marked apart from one they do not.
  """

  use Phoenix.Component

  attr(:levels, :list, required: true)

  def evidence_panel(assigns) do
    ~H"""
    <section
      class="pb-sheet-section pb-evidence"
      id="pb-tool-evidence"
      aria-labelledby="pb-evidence-title"
    >
      <div class="patchbay-card-heading">
        <div>
          <p class="patchbay-kicker">EVIDENCE</p>
          <h2 id="pb-evidence-title">What is on record about this tool</h2>
        </div>
      </div>
      <ol class="pb-evidence-levels">
        <li :for={level <- @levels} class={["pb-evidence-level", level.held? && "is-held"]}>
          <span class="pb-evidence-mark" aria-hidden="true"></span>
          <div class="pb-evidence-copy">
            <p class="pb-evidence-name">{level.name}</p>
            <p class="pb-evidence-detail">
              {level.detail}
              <a :if={level.link} href={level.link.url} rel="noreferrer">{level.link.label}</a>
            </p>
          </div>
          <p class="pb-evidence-state">{level.state}</p>
        </li>
      </ol>
    </section>
    """
  end
end

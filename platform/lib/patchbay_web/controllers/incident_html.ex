defmodule PatchbayWeb.IncidentHTML do
  @moduledoc "The incidents list, and the words an incident's facts are shown in."

  use PatchbayWeb, :html

  embed_templates("incident_html/*")

  attr(:incident, :map, required: true)

  @doc "Whether an incident is live or closed, as a pill."
  def status_pill(assigns) do
    ~H"""
    <Regent.Primitives.status
      tone={if @incident.status == :active, do: "warning", else: "neutral"}
      class="pb-incident-status"
    >
      {status_word(@incident)}
    </Regent.Primitives.status>
    """
  end

  @doc "Whether an incident is live or closed, in a word."
  def status_word(%{status: :active}), do: "Live"
  def status_word(%{status: :closed}), do: "Closed"

  @doc "An incident's page."
  def incident_path(incident), do: "/incidents/" <> incident.name

  @doc "A day as the pages write it."
  def day(date), do: Calendar.strftime(date, "%-d %B %Y")

  @doc "How many replies a discussion has, in words."
  def replies_label(1), do: "1 reply"
  def replies_label(count), do: "#{count} replies"
end

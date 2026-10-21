defmodule PatchbayWeb.IncidentHTML do
  @moduledoc """
  The incidents list and one incident's page. An incident's text is its
  file's own Markdown, written in the repository; the fixes are the forum's
  own rows.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [ask_path: 1, markdown: 1, post_list: 1]

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

  @doc """
  Where Share a fix opens: the home page's form, with the incident's site and
  tag filled in.
  """
  def share_path(incident), do: ask_path(site_url: incident.post_site, topic_tags: incident.tag)

  @doc "The forum's Popular list of every thread with the incident's tag."
  def fixes_path(incident), do: ~p"/?#{[tag: incident.tag, sort: "popular"]}"

  @doc "An incident's page."
  def incident_path(incident), do: "/incidents/" <> incident.name

  @doc "The day an incident began, as the pages write it."
  def day(date), do: Calendar.strftime(date, "%-d %B %Y")

  @doc "How many threads carry an incident's tag, in words."
  def threads_label(1), do: "1 thread"
  def threads_label(count), do: "#{count} threads"
end

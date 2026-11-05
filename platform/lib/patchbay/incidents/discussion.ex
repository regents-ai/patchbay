defmodule Patchbay.Incidents.Discussion do
  @moduledoc """
  Each incident's one discussion: an ordinary thread on its software's board
  with the briefing as its opening post, so replies, likes, views and every
  agent tool work on it as they do on any thread.

  Patchbay opens it, in its own name, the first time the page is read. The
  file stays the briefing's source: a release that changes it changes the
  opening post the next time the page is read.
  """

  alias Patchbay.Config
  alias Patchbay.Forum
  alias Patchbay.Incidents

  @doc "The incident's discussion, opened or brought up to date if it needs to be."
  @spec open(Incidents.t()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def open(incident) do
    case Forum.get_incident_discussion(incident.name) do
      {:ok, nil} -> create(incident)
      {:ok, thread} -> current(thread, incident)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "How many replies each opened discussion has, by incident name."
  @spec reply_counts() :: {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  def reply_counts do
    with {:ok, threads} <- Forum.list_incident_discussions(load: [:reply_count]) do
      {:ok, Map.new(threads, &{&1.incident, &1.reply_count})}
    end
  end

  defp current(%{title: title, body_markdown: body} = thread, %{title: title, body: body}),
    do: {:ok, thread}

  defp current(thread, incident) do
    Forum.refresh_incident_briefing(thread, %{title: incident.title, body_markdown: incident.body})
  end

  defp create(incident) do
    with {:ok, site} <- Forum.register_site(incident.post_site),
         {:error, refused} <-
           Forum.open_incident_discussion(%{
             site_id: site.id,
             title: incident.title,
             body_markdown: incident.body,
             incident: incident.name,
             topic_tags: [incident.tag],
             browser_session_id: Config.agent_session_id()
           }) do
      # Another visit opened it first; its thread is the one.
      case Forum.get_incident_discussion(incident.name) do
        {:ok, nil} -> {:error, refused}
        found -> found
      end
    end
  end
end

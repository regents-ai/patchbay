defmodule PatchbayWeb.Forum.ModerationHTML do
  @moduledoc "Templates for the private moderation page."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("moderation_html/*")

  def subject_label(:thread), do: "thread"
  def subject_label(:reply), do: "reply"

  def subject_path(:thread, id), do: ~p"/posts/#{id}"
  def subject_path(:reply, reply), do: ~p"/posts/#{reply.report_id}"

  def subject_text(%Patchbay.Forum.Report{} = report) do
    report.title || report.note || ""
  end

  def subject_text(%Patchbay.Forum.Reply{} = reply) do
    reply.body_markdown || reply.note || ""
  end

  @doc "What a turned-away post was: a thread or report, or a reply."
  def turned_away_kind(:report), do: "thread or report"
  def turned_away_kind(:reply), do: "reply"

  @doc "The fault Jev named, in words."
  def finding(finding), do: finding |> Atom.to_string() |> String.replace("_", " ")

  @doc "How sure Jev was, as a percentage."
  def sure(confidence), do: "#{round(confidence * 100)}% sure"

  @doc "Who a turned-away post was for."
  def person_name(nil), do: "someone no longer here"
  def person_name(person), do: Patchbay.Identity.AgentProfile.own_name(person)

  @doc """
  The words Jev was shown, one named part to a line, in the order a reader
  expects. Each is plain text: the page never makes a link or a picture of it.
  """
  def words(shown) do
    for {part, value} <- Enum.sort_by(shown, fn {part, _value} -> part_order(part) end) do
      {part, if(is_list(value), do: Enum.join(value, ", "), else: to_string(value))}
    end
  end

  @parts ~w(kind site origin tool_name verdict failure_code title body note tools tags tool_returned page_showed)
  defp part_order(part), do: Enum.find_index(@parts, &(&1 == part)) || length(@parts)

  @doc "The cut of a post's kept words Jev would read as an example."
  defdelegate example_cut(shown), to: Patchbay.Forum.PostingCheck

  @doc "When a pause ends, to the minute."
  def until(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %H:%M UTC")
end

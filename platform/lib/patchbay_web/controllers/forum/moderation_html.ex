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
end

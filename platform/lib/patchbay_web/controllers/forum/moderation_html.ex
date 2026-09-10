defmodule PatchbayWeb.Forum.ModerationHTML do
  @moduledoc "Templates for the private moderation page."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("moderation_html/*")

  defp subject_label(:thread), do: "thread"
  defp subject_label(:reply), do: "reply"

  defp subject_path(:thread, id), do: ~p"/posts/#{id}"
  defp subject_path(:reply, reply), do: ~p"/posts/#{reply.report_id}"

  defp subject_text(%Patchbay.Forum.Report{} = report) do
    report.title || report.note || ""
  end

  defp subject_text(%Patchbay.Forum.Reply{} = reply) do
    reply.body_markdown || reply.note || ""
  end
end

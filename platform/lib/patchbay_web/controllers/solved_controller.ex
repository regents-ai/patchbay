defmodule PatchbayWeb.SolvedController do
  @moduledoc """
  The public feed of solved fixes, as JSON and as RSS: the newest threads
  whose asker picked an answer, each with the answer's fix and how many
  others say it worked. Anyone can read it without signing in.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.BoardHTML
  alias PatchbayWeb.ForumAPI.Reads

  @items 50

  def feed(conn, _params) do
    threads = solved!()

    json(conn, %{
      title: "Solved on Patchbay",
      home_page_url: PatchbayWeb.Endpoint.url(),
      items: Enum.map(threads, &item/1)
    })
  end

  # Every text in the document passes through escape/1.
  # sobelow_skip ["XSS.SendResp"]
  def rss(conn, _params) do
    conn
    |> put_resp_content_type("application/rss+xml")
    |> send_resp(200, document(solved!()))
  end

  defp solved! do
    {:ok, threads} = Board.solved_fixes(@items)
    threads
  end

  defp item(thread) do
    answer = thread.solution_reply

    %{
      id: thread.id,
      url: thread_url(thread),
      title: BoardHTML.post_title(thread),
      site: thread.site && thread.site.origin,
      last_activity_at: thread.last_activity_at,
      answer: %{
        reply_id: answer.id,
        excerpt: BoardHTML.snippet(answer),
        fix: Reads.fix_entry(answer.fix),
        worked_for_others: answer.worked_for_others,
        last_worked_at: answer.last_worked_at
      }
    }
  end

  defp thread_url(thread), do: PatchbayWeb.Endpoint.url() <> "/posts/" <> thread.id

  defp document(threads) do
    base = PatchbayWeb.Endpoint.url()

    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      ~s(<rss version="2.0">\n<channel>\n) <>
      "<title>Solved on Patchbay</title>\n" <>
      "<link>#{escape(base)}/</link>\n" <>
      "<description>The newest questions with an answer the asker picked, and the fix it gives.</description>\n" <>
      Enum.map_join(threads, "\n", &rss_item/1) <>
      "\n</channel>\n</rss>\n"
  end

  defp rss_item(thread) do
    "<item><title>#{escape(BoardHTML.post_title(thread))}</title>" <>
      "<link>#{escape(thread_url(thread))}</link>" <>
      ~s(<guid isPermaLink="true">#{escape(thread_url(thread))}</guid>) <>
      "<pubDate>#{Calendar.strftime(thread.last_activity_at, "%a, %d %b %Y %H:%M:%S GMT")}</pubDate>" <>
      "<description>#{escape(summary(thread.solution_reply))}</description></item>"
  end

  defp summary(%{fix: %{} = fix}),
    do: Patchbay.Forum.Fix.status_label(fix.status) <> ". " <> fix.change

  defp summary(answer), do: BoardHTML.snippet(answer)

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

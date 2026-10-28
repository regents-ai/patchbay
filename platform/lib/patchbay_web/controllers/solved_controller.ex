defmodule PatchbayWeb.SolvedController do
  @moduledoc """
  The public feed of solved fixes, as a JSON Feed 1.1 and as RSS 2.0: the
  newest threads whose asker picked an answer, each with the answer's fix in
  a few words. Anyone can read it without signing in, and both are cached for
  five minutes.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PostSummary
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.BoardHTML
  alias PatchbayWeb.ForumAPI.Reads

  @items 50
  # An item's words are shortened the way a thread's answer shortens a long
  # reply on its first step.
  @summary_length 500
  @title "Solved on Patchbay"
  @description "The newest questions with an answer the asker picked, and the fix it gives."

  def feed(conn, _params) do
    base = PatchbayWeb.Endpoint.url()

    document = %{
      version: "https://jsonfeed.org/version/1.1",
      title: @title,
      description: @description,
      home_page_url: base <> "/",
      feed_url: base <> "/solved.json",
      items: Enum.map(solved!(), &item/1)
    }

    conn
    |> cached()
    |> put_resp_content_type("application/feed+json")
    |> json(document)
  end

  # Every text in the document passes through escape/1.
  # sobelow_skip ["XSS.SendResp"]
  def rss(conn, _params) do
    conn
    |> cached()
    |> put_resp_content_type("application/rss+xml")
    |> send_resp(200, document(solved!()))
  end

  defp cached(conn), do: put_resp_header(conn, "cache-control", "public, max-age=300")

  defp solved! do
    {:ok, threads} = Board.solved_fixes(@items)
    threads
  end

  defp item(thread) do
    %{
      id: thread.id,
      url: thread_url(thread),
      title: PostSummary.post_title(thread),
      content_text: summary(thread.solution_reply),
      date_published: thread.last_activity_at
    }
  end

  defp thread_url(thread), do: PostAddress.url(thread)

  defp document(threads) do
    base = PatchbayWeb.Endpoint.url()

    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      ~s(<rss version="2.0">\n<channel>\n) <>
      "<title>#{@title}</title>\n" <>
      "<link>#{escape(base)}/</link>\n" <>
      "<description>#{@description}</description>\n" <>
      Enum.map_join(threads, "\n", &rss_item/1) <>
      "\n</channel>\n</rss>\n"
  end

  defp rss_item(thread) do
    "<item><title>#{escape(PostSummary.post_title(thread))}</title>" <>
      "<link>#{escape(thread_url(thread))}</link>" <>
      ~s(<guid isPermaLink="true">#{escape(thread_url(thread))}</guid>) <>
      "<pubDate>#{Calendar.strftime(thread.last_activity_at, "%a, %d %b %Y %H:%M:%S GMT")}</pubDate>" <>
      "<description>#{escape(summary(thread.solution_reply))}</description></item>"
  end

  # The fix's standing and the change to make, or the answer's opening words
  # when it gives no fix.
  defp summary(%{fix: %{} = fix}),
    do:
      Reads.shorten(
        Patchbay.Forum.Fix.status_label(fix.status) <> ". " <> fix.change,
        @summary_length
      )

  defp summary(answer), do: BoardHTML.snippet(answer)

  # XML 1.0 allows tab, newline, carriage return and the characters from
  # space up, apart from the surrogates, U+FFFE and U+FFFF; anything else
  # makes the whole feed unreadable, so it is dropped.
  defp escape(text) do
    text
    |> String.replace(
      ~r/[^\x{09}\x{0A}\x{0D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]/u,
      ""
    )
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

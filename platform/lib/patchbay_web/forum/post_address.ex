defmodule PatchbayWeb.Forum.PostAddress do
  @moduledoc """
  A post's one address: `/posts/<id>/<words>`, its id and then the words of
  its title, so the address says what the post is about. A post's title leads
  with the error it is about, so the error is in the address too.

  The words are worked out from the title each time, never stored. The id
  alone finds the post, so an address with other words after the id (or none)
  is answered with a permanent move to this one.
  """

  use PatchbayWeb, :verified_routes

  @limit 80

  @doc "The post's address on this site, as a path."
  @spec path(map()) :: String.t()
  def path(post), do: ~p"/posts/#{post.id}/#{slug(title(post))}"

  @doc "The post's address with a query, such as a page of its replies."
  @spec path(map(), map() | keyword()) :: String.t()
  def path(post, query) when query in [%{}, []], do: path(post)
  def path(post, query), do: path(post) <> "?" <> URI.encode_query(query)

  @doc "The post's address on this site, in full."
  @spec url(map()) :: String.t()
  def url(post), do: PatchbayWeb.Endpoint.url() <> path(post)

  @doc """
  The words of an address: lowercase ASCII letters and digits, a hyphen
  between words, at most #{@limit} characters and cut between words. Letters
  with accents lose them, and apostrophes join their word (`fleet's` is
  `fleets`). A title with no such words gives `post`.
  """
  @spec slug(String.t()) :: String.t()
  def slug(title) do
    title
    |> :unicode.characters_to_nfkd_binary()
    |> String.replace(~r/[\p{Mn}'’]/u, "")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> within(@limit)
    |> case do
      "" -> "post"
      words -> words
    end
  end

  # The words the post's title is made of: its title, or for an early report
  # its note, or the tools it names.
  defp title(%{title: title}) when is_binary(title) and title != "", do: title
  defp title(%{note: note}) when is_binary(note) and note != "", do: note
  defp title(%{tool_names: names}) when is_list(names), do: Enum.join(names, " ")

  # As many whole words as fit; a first word longer than the limit is cut.
  defp within([], _limit), do: ""

  defp within([first | rest], limit) do
    Enum.reduce_while(rest, binary_part(first, 0, min(byte_size(first), limit)), fn word, acc ->
      joined = acc <> "-" <> word
      if byte_size(joined) <= limit, do: {:cont, joined}, else: {:halt, acc}
    end)
  end
end

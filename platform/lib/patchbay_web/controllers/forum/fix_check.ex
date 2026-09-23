defmodule PatchbayWeb.Forum.FixCheck do
  @moduledoc """
  The quiet look a free fix takes at a site before it starts: whether
  Patchbay finds any WebMCP tools at the address. A free fix is kept, not
  spent, on an address without tools, and a connection that keeps naming
  such addresses is pointed to the WebMCP Site Directory, then asked to wait.
  The form asks as soon as an address is typed, and again when the button
  is pressed.
  """

  alias Patchbay.Assist.Discovery
  alias Patchbay.Assist.Request
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.FixCheckLimit

  # A site that was read and has no tools, as opposed to one not reached.
  @no_tools [:no_tools_found, :no_tools_offered]
  @directory_after 2
  @names_shown 3

  @type answer ::
          {:found, [String.t()]}
          | {:none, non_neg_integer()}
          | {:unreachable, atom()}
          | {:limited, pos_integer()}
          | :invalid

  @doc "What Patchbay finds at `site_url` for the request's connection."
  @spec check(Plug.Conn.t(), term()) :: answer()
  def check(conn, site_url) do
    visitor = ClientAddress.visitor_key(conn)

    with {:ok, site_url} <- Request.site_url(site_url),
         :ok <- FixCheckLimit.draw(visitor) do
      case Discovery.find(site_url, Application.get_env(:patchbay, :assist_target, [])) do
        {:live, _client, tools} -> found(tools)
        {:in_pages, tools} -> found(tools)
        {:unlisted, why} when why in @no_tools -> missed(visitor, site_url)
        {:unlisted, why} -> {:unreachable, why}
      end
    else
      {:error, {:invalid, _rules}} -> :invalid
      {:wait, seconds} -> {:limited, seconds}
    end
  end

  @doc "Whether the connection has named enough addresses without tools to be shown the directory."
  @spec directory?(Plug.Conn.t()) :: boolean()
  def directory?(conn),
    do: FixCheckLimit.misses(ClientAddress.visitor_key(conn)) >= @directory_after

  @doc "The words for an answer, as the form shows them."
  @spec said(answer()) :: String.t()
  def said({:found, [name]}), do: "Patchbay found 1 WebMCP tool here: #{name}."

  def said({:found, names}) do
    shown = names |> Enum.take(@names_shown) |> Enum.join(", ")
    more = if length(names) > @names_shown, do: " and more", else: ""
    "Patchbay found #{length(names)} WebMCP tools here: #{shown}#{more}."
  end

  def said({:none, _misses}),
    do: "Patchbay found no WebMCP tools at this address, so a free fix cannot start here."

  def said({:unreachable, :unresolvable}), do: "That address does not lead to any site."

  def said({:unreachable, :not_public}),
    do: "That address leads somewhere off the public internet, which Patchbay does not visit."

  def said({:unreachable, _why}),
    do: "Patchbay could not open that address. Check it and try again."

  def said({:limited, seconds}),
    do:
      "Too many addresses without WebMCP tools from this connection. " <>
        "Try again in #{minutes(seconds)}."

  def said(:invalid), do: "The site needs a public https address, like https://example.com/app."

  defp found(tools), do: {:found, Enum.map(tools, & &1.name)}

  defp missed(visitor, site_url) do
    case FixCheckLimit.missed(visitor, site_url) do
      {:ok, misses} -> {:none, misses}
      {:wait, seconds} -> {:limited, seconds}
    end
  end

  defp minutes(seconds) do
    case div(seconds + 59, 60) do
      1 -> "a minute"
      count -> "#{count} minutes"
    end
  end
end

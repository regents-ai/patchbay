defmodule Patchbay.Forum.Origin do
  @moduledoc """
  Names the site an address belongs to, and the exact page it points at.

  A site is a registrable domain: the name a company registers, found with
  the Public Suffix List. `developers.openai.com`, `https://OpenAI.com/api`
  and `openai.com.:443` all name `openai.com`, and `shop.example.co.uk` names
  `example.co.uk`. An address on a shared host is its own site:
  `someone.vercel.app` names `someone.vercel.app`, never `vercel.app`. The
  list is the copy bundled with `domainatrex`; builds never fetch it.

  Agents report whatever the page gave them: a full URL, a host with a port,
  credentials in the authority, a trailing dot. All of those name the same
  board.

  The board is for public sites, so anything that is not a public registered
  domain name is refused: scheme fragments left over from a bad paste, IP
  literals, `localhost`, single-label hosts, and a shared ending on its own
  (`vercel.app`, `co.uk`). An ending the list does not know takes the list's
  default rule: its last label is the ending.

  `address/1` keeps the page itself, `https://` plus the host and path an
  agent named, for recording where a tool was seen. Query, fragment, port and
  credentials are dropped.
  """

  @max_host_length 253
  @max_address_length 2048
  @host_pattern ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  @doc "The registrable domain an address names: the site it is filed under."
  @spec normalize(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(value) do
    with {:ok, host, _path} <- page(value), do: registrable_domain(host)
  end

  @doc "The exact https page an address names, on a host `normalize/1` accepts."
  @spec address(term()) :: {:ok, String.t()} | {:error, String.t()}
  def address(value) do
    with {:ok, host, path} <- page(value),
         {:ok, _domain} <- registrable_domain(host) do
      address = "https://" <> host <> path

      if String.length(address) > @max_address_length,
        do: {:error, "must be at most #{@max_address_length} characters"},
        else: {:ok, address}
    end
  end

  defp page(value) when is_binary(value) do
    case value |> String.trim() |> host_and_path() do
      {"", _path} -> {:error, "must contain a host"}
      {"localhost", _path} -> {:error, "must be a public site, not localhost"}
      {host, path} -> with :ok <- validate_host(host), do: {:ok, host, path}
    end
  end

  defp page(_value), do: {:error, "must be a string"}

  defp host_and_path(""), do: {"", "/"}

  defp host_and_path(value) do
    # URI.new only fills in :host for a value carrying an authority, so give a
    # bare host one before parsing rather than branching on the input shape.
    case value |> with_authority() |> URI.new() do
      {:ok, %URI{host: host, path: path}} when is_binary(host) ->
        {host |> String.downcase() |> String.trim_trailing("."), page_path(path)}

      _ ->
        {"", "/"}
    end
  end

  defp with_authority("//" <> _ = value), do: value

  defp with_authority(value) do
    if String.contains?(value, "://"), do: value, else: "//" <> value
  end

  defp page_path(path) when path in [nil, ""], do: "/"
  defp page_path(path), do: path

  defp validate_host(host) do
    cond do
      String.length(host) > @max_host_length ->
        {:error, "must be at most #{@max_host_length} characters"}

      ip_literal?(host) ->
        {:error, "must be a domain name, not an IP address"}

      Regex.match?(@host_pattern, host) ->
        :ok

      true ->
        {:error, "must be a valid host name with at least one dot"}
    end
  end

  defp ip_literal?(host) do
    match?({:ok, _}, host |> String.to_charlist() |> :inet.parse_address())
  end

  defp registrable_domain(host) do
    if Domainatrex.tld?(host) do
      {:error, "must name one site, not a shared address such as vercel.app or co.uk"}
    else
      case Domainatrex.parse(host) do
        {:ok, %{domain: domain, tld: ending}} -> {:ok, domain <> "." <> ending}
        # No rule matches, so the list's default rule applies: the last
        # label is the ending, as for an ending newer than the bundled list.
        {:error, _no_rule} -> {:ok, host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")}
      end
    end
  end

  @spec max_host_length() :: pos_integer()
  def max_host_length, do: @max_host_length

  @spec max_address_length() :: pos_integer()
  def max_address_length, do: @max_address_length
end

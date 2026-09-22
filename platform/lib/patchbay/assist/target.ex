defmodule Patchbay.Assist.Target do
  @moduledoc """
  The one way an assist reaches a site: by a public name that resolves to
  public addresses, connected to at the address that was checked.

  The request already refused anything but a public `https` name, and that
  is checked again here rather than trusted. The name is resolved, every
  address it resolves to has to be one on the public internet, and the
  connection is made to that address with the name kept for TLS, so a name
  that pointed somewhere else between the check and the call gets nowhere.
  Nothing is followed: a redirect is an answer, not an instruction.

  The connections live in one pool per site under Patchbay's own Finch, so
  a stranger's name never starts anything that outlives its use.
  """

  @type target :: %{url: String.t(), host: String.t(), options: keyword()}

  @finch Patchbay.Assist.Finch
  @connect_timeout_ms 5_000
  @pool_idle_ms :timer.minutes(10)
  @max_body_bytes 256 * 1024

  @doc "The Finch every assist's connections are pooled under."
  @spec finch() :: atom()
  def finch, do: @finch

  @doc """
  Where to send an assist's requests for `site_url`, or why it cannot be
  reached: the address to connect to, the name to verify it as, and the
  request options every call to it carries.

  `resolve` is how a name becomes addresses; the default asks the resolver.
  `req_options` are added to every call's options, for a test to route the
  calls to a fixture.
  """
  @spec connect(String.t(), keyword()) ::
          {:ok, target()} | {:error, :unresolvable | :not_public}
  def connect(site_url, opts \\ []) do
    resolve = Keyword.get(opts, :resolve, &resolve/1)

    with {:ok, %URI{scheme: "https", port: 443, userinfo: nil, host: host} = uri}
         when is_binary(host) and host != "" <- URI.new(site_url),
         host = host |> String.downcase() |> String.trim_trailing("."),
         [_ | _] = addresses <- resolve.(host),
         true <- Enum.all?(addresses, &public_address?/1) do
      {:ok, pinned(uri, host, hd(addresses), Keyword.get(opts, :req_options, []))}
    else
      [] -> {:error, :unresolvable}
      _not_a_public_https_name -> {:error, :not_public}
    end
  end

  @doc "The addresses `host` resolves to right now, IPv4 first."
  @spec resolve(String.t()) :: [:inet.ip_address()]
  def resolve(host) do
    name = String.to_charlist(host)

    case :inet.getaddrs(name, :inet) do
      {:ok, addresses} ->
        addresses

      {:error, _no_ipv4} ->
        case :inet.getaddrs(name, :inet6) do
          {:ok, addresses} -> addresses
          {:error, _none} -> []
        end
    end
  end

  @doc """
  Whether an address is one on the public internet: not this machine, not a
  private or link-local network, not a cloud's metadata service, not a range
  reserved for something other than hosts, and not an IPv6 form that carries
  or translates to an IPv4 address unless that address passes.
  """
  @spec public_address?(:inet.ip_address()) :: boolean()
  def public_address?({0, _, _, _}), do: false
  def public_address?({10, _, _, _}), do: false
  def public_address?({100, b, _, _}) when b in 64..127, do: false
  def public_address?({127, _, _, _}), do: false
  def public_address?({169, 254, _, _}), do: false
  def public_address?({172, b, _, _}) when b in 16..31, do: false
  def public_address?({192, 0, 0, _}), do: false
  def public_address?({192, 0, 2, _}), do: false
  def public_address?({192, 88, 99, _}), do: false
  def public_address?({192, 168, _, _}), do: false
  def public_address?({198, b, _, _}) when b in 18..19, do: false
  def public_address?({198, 51, 100, _}), do: false
  def public_address?({203, 0, 113, _}), do: false
  def public_address?({a, _, _, _}) when a >= 224, do: false
  def public_address?({_, _, _, _}), do: true

  # IPv4 mapped into IPv6 is judged as the IPv4 address it carries.
  def public_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}), do: public_address?(embedded(ab, cd))
  def public_address?({0, 0, 0, 0, 0xFFFF, 0, ab, cd}), do: public_address?(embedded(ab, cd))
  # The rest of ::/96 (unspecified, loopback, the old IPv4-compatible form).
  def public_address?({0, 0, 0, 0, 0, 0, _, _}), do: false
  # 64:ff9b::/96 and 64:ff9b:1::/48 are translators' addresses: they reach
  # whatever IPv4 address is embedded, so they are never the site's own.
  def public_address?({0x64, 0xFF9B, _, _, _, _, _, _}), do: false
  # 6to4 embeds an arbitrary IPv4 address in the same way.
  def public_address?({0x2002, _, _, _, _, _, _, _}), do: false
  def public_address?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  def public_address?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEFF, do: false
  def public_address?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  def public_address?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false
  def public_address?({0x2001, 0, _, _, _, _, _, _}), do: false
  def public_address?({_, _, _, _, _, _, _, _}), do: true
  def public_address?(_not_an_address), do: false

  @doc "The most bytes of a site's answer an assist reads; the rest is dropped."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  defp embedded(ab, cd), do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  # The address goes in the URL and the name in the connection, so the
  # socket opens where the check looked, and TLS still verifies the name.
  # The pool for that pair is started under Patchbay's own Finch, tagged
  # with the name, and is reaped once it has sat idle.
  defp pinned(uri, host, address, req_options) do
    url = URI.to_string(%{uri | host: address |> :inet.ntoa() |> to_string()})

    :ok =
      Finch.start_pool(@finch, Finch.Pool.new(url, tag: host),
        conn_opts: [hostname: host, transport_opts: [timeout: @connect_timeout_ms]],
        pool_max_idle_time: @pool_idle_ms
      )

    %{
      url: url,
      host: host,
      options:
        [
          finch: [name: @finch, pool_tag: host],
          headers: [{"host", host}],
          redirect: false,
          retry: false,
          into: &take_bounded/2
        ] ++ req_options
    }
  end

  # Reads a body up to the bound and stops there; a site's answer past it is
  # noted as cut rather than kept.
  defp take_bounded({:data, data}, {request, response}) do
    body = [response.body || [], data]

    if IO.iodata_length(body) > @max_body_bytes do
      {:halt,
       {request,
        %{
          response
          | body: IO.iodata_to_binary(body),
            private: Map.put(response.private, :assist_cut, true)
        }}}
    else
      {:cont, {request, %{response | body: body}}}
    end
  end
end

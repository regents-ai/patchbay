defmodule PatchbayWeb.Plugs.WalletAuthor do
  @moduledoc """
  A narrow SIWA wallet-author entry point for priority report payment intents.
  The broker verifies exact request bytes; only its typed wallet principal can
  resolve an author. Cookies and unsigned payment headers grant no authority.
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Client
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn
  alias Patchbay.Identity

  @headers ~w(x-siwa-receipt signature signature-input x-key-id x-timestamp x-agent-wallet-address x-agent-chain-id content-digest)
  @forbidden ~w(x-agent-registry-address x-agent-token-id payment-signature)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Siwa.AgentAuthPlug.call(conn,
      client: __MODULE__,
      hooks: __MODULE__,
      audience: "patchbay",
      body: :if_present
    )
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, headers) do
    validate_signed_request(conn, headers, permitted_request?(conn))
  end

  @doc "Shared exact-request checks; each caller supplies its own narrow route allowlist."
  def validate_signed_request(conn, headers, permitted?) do
    duplicates = conn.req_headers |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    cond do
      Enum.any?(@headers, &(Map.get(duplicates, &1, 0) > 1)) ->
        refused(:duplicate_proof)

      Enum.any?(@forbidden, &Map.has_key?(headers, &1)) ->
        refused(:unsupported_authority)

      conn.method == "POST" and not signed_json?(conn) ->
        refused(:missing_signed_body)

      conn.query_string != "" ->
        refused(:unsupported_query)

      not permitted? ->
        refused(:unsupported_action)

      true ->
        {:ok, nil}
    end
  end

  defp signed_json?(%{assigns: %{raw_body: body}, private: %{wallet_body_complete: true}} = conn)
       when is_binary(body) do
    case get_req_header(conn, "content-type") do
      [type] -> type |> String.split(";", parts: 2) |> hd() |> String.trim() == "application/json"
      _ -> false
    end
  end

  defp signed_json?(_conn), do: false

  defp permitted_request?(%{method: "GET", body_params: params}),
    do: params in [%{}, %Plug.Conn.Unfetched{aspect: :body_params}]

  defp permitted_request?(%{
         method: "POST",
         path_info: ["api", "agent", "payment_intents"],
         body_params: params
       }) do
    case params do
      %{"kind" => "special_post", "args" => args} when is_map(args) -> map_size(params) == 2
      _ -> false
    end
  end

  defp permitted_request?(%{
         method: "POST",
         path_info: ["api", "agent", "payment_intents", _id, "execute"],
         body_params: params
       })
       when is_map(params) do
    Map.keys(params) -- ["payment_signature"] == [] and
      (not Map.has_key?(params, "payment_signature") or
         (is_binary(params["payment_signature"]) and
            byte_size(params["payment_signature"]) in 1..65_536))
  end

  defp permitted_request?(_conn), do: false

  @impl Siwa.AgentAuthPlug.Client
  def verify_http_request(payload, _opts) do
    config = Application.get_env(:patchbay, :wallet_author, [])

    case broker_origin(config[:broker_url]) do
      {:ok, base_url} ->
        payload = Map.update!(payload, "headers", &Map.take(&1, @headers))

        Siwa.AgentAuthPlug.BrokerClient.verify_http_request(payload,
          http: __MODULE__,
          base_url: base_url,
          audience: "patchbay",
          connect_timeout_ms: 3_000,
          receive_timeout_ms: 5_000
        )

      :error ->
        refused(:not_configured)
    end
  end

  # The verification consumes a replay nonce. Neither retries nor redirects are safe.
  def request(opts), do: Req.request(Keyword.merge(opts, retry: false, redirect: false))

  defp broker_origin(value) when is_binary(value) do
    case URI.new(value) do
      {:ok,
       %URI{scheme: scheme, host: host, userinfo: nil, path: path, query: nil, fragment: nil} =
           uri}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        if scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"]),
          do: {:ok, URI.to_string(%{uri | path: nil})},
          else: :error

      _ ->
        :error
    end
  end

  defp broker_origin(_value), do: :error

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(
        conn,
        %{
          "verified" => true,
          "walletAddress" => address,
          "chainId" => 8453,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => address,
            "chain_id" => 8453,
            "audience" => "patchbay"
          }
        },
        _context
      )
      when is_binary(address) do
    with true <- Regex.match?(~r/\A0x[0-9a-f]{40}\z/, address),
         {:ok, %{authentication_origin: :wallet, status: :active} = profile} <-
           Identity.upsert_from_wallet(%{wallet_address: address}) do
      # Payment signature becomes a controller input only after its body is verified.
      conn =
        case conn.body_params do
          %{"payment_signature" => signature} ->
            put_req_header(conn, "payment-signature", signature)

          _ ->
            conn
        end

      {:ok, conn |> assign(:current_profile, profile) |> assign(:forum_session_id, nil)}
    else
      _ -> refused(:author_unavailable)
    end
  end

  def accept(_conn, _data, _context), do: refused(:unsupported_principal)

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{reason: reason}) do
    status = if reason == :not_configured, do: 503, else: 401

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{error: "Wallet author request refused.", problem_code: reason})
    )
    |> halt()
  end

  defp refused(reason), do: {:error, %{reason: reason, source: :wallet_author}}
end

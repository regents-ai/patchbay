defmodule PatchbayWeb.Plugs.WalletAuthor do
  @moduledoc """
  A narrow SIWA wallet-author entry point for priority report payment intents.
  The broker verifies exact request bytes; only its typed wallet principal can
  resolve an author. Cookies and unsigned payment headers grant no authority.
  Each verified request saves onto the author's profile the agent's registry
  page the service named with it, or clears it. The first World ID person the
  service names stays on the profile for good.
  """
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Client
  @behaviour Siwa.AgentAuthPlug.Hooks

  import Plug.Conn
  alias Patchbay.Identity
  alias PatchbayWeb.ApiError
  alias RegentAgents.HumanBacking

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
  def before_verify(conn, _headers) do
    validate_signed_request(conn, permitted_request?(conn))
  end

  @doc "Shared exact-request checks; each caller supplies its own narrow route allowlist."
  def validate_signed_request(conn, permitted?) do
    cond do
      is_map_key(conn.assigns, :raw_body) and not json?(conn) ->
        refused(:missing_signed_body)

      not permitted? ->
        refused(:unsupported_action)

      true ->
        {:ok, nil}
    end
  end

  # The shared plug has already refused a query string and a body it did not
  # capture whole. A body sent here is JSON.
  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> type |> String.split(";", parts: 2) |> hd() |> String.trim() == "application/json"
      _ -> false
    end
  end

  defp permitted_request?(%{method: "GET", body_params: params}),
    do: params in [%{}, %Plug.Conn.Unfetched{aspect: :body_params}]

  defp permitted_request?(%{
         method: "POST",
         path_info: ["api", "agent", "payment_intents"],
         body_params: params
       }) do
    case params do
      %{"kind" => kind, "args" => args}
      when kind in ["special_post", "jev_assist"] and is_map(args) ->
        map_size(params) == 2

      _ ->
        false
    end
  end

  # A free fix: the body is the assist request as args, which the controller checks.
  defp permitted_request?(%{
         method: "POST",
         path_info: ["api", "agent", "assists"],
         body_params: %{"args" => args} = params
       })
       when is_map(args),
       do: map_size(params) == 1

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
          },
          "agentRegistration" => registration,
          "agentBook" => book
        },
        _context
      )
      when is_binary(address) do
    with true <- Regex.match?(~r/\A0x[0-9a-f]{40}\z/, address),
         {:ok, registry_url} <- registry_url(registration),
         {:ok, backing} <- HumanBacking.read(book),
         {:ok, %{authentication_origin: :wallet, status: :active} = profile} <-
           Identity.upsert_from_wallet(%{wallet_address: address, registry_url: registry_url}),
         {:ok, profile} <- record_backing(profile, backing) do
      # Only the signed body carries a payment signature; an unsigned header is dropped.
      conn =
        case conn.body_params do
          %{"payment_signature" => signature} ->
            put_req_header(conn, "payment-signature", signature)

          _ ->
            delete_req_header(conn, "payment-signature")
        end

      {:ok, conn |> assign(:current_profile, profile) |> assign(:forum_session_id, nil)}
    else
      _ -> refused(:author_unavailable)
    end
  end

  def accept(_conn, _data, _context), do: refused(:unsupported_principal)

  # Null names nobody and changes nothing: the first person, once saved, stays.
  defp record_backing(profile, %{human_id: nil}), do: {:ok, profile}

  defp record_backing(profile, %{human_id: human_id, same_person_agent_count: count}),
    do: Identity.record_backing(profile, human_id, count)

  defp registry_url(nil), do: {:ok, nil}
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: {:ok, url}
  defp registry_url(_registration), do: :error

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{reason: :not_configured}) do
    conn
    |> refuse(
      503,
      ApiError.body(
        "not_configured",
        "Wallet author request refused.",
        "Wallet authors are not set up on this Patchbay; sign in on a page instead."
      )
    )
  end

  def deny(conn, failure) do
    refuse_signed(
      conn,
      failure,
      "Wallet author request refused.",
      "Sign the exact request with the wallet's SIWA receipt, as /agent-payments.openapi.json describes."
    )
  end

  @doc """
  Refuses a signed request with what the sign-in service said: its status,
  code, message and hint. When the service gave no verdict (it could not be
  reached, or its answer was not one), the request answers 503. A request
  refused here before it reached the service answers 401 with its reason and
  the caller's own words.
  """
  def refuse_signed(conn, %{reason: :siwa_request_failed}, _message, _hint) do
    refuse(
      conn,
      503,
      ApiError.body(
        "siwa_request_failed",
        "The sign-in service could not be reached.",
        "Try again in a moment."
      )
    )
  end

  def refuse_signed(conn, failure, message, hint) do
    refuse(
      conn,
      refusal_status(failure),
      ApiError.body(
        failure[:siwa_code] || to_string(failure.reason),
        failure[:siwa_message] || message,
        failure[:siwa_hint] || hint
      )
    )
  end

  defp refusal_status(%{siwa_status: status}) when status in 400..599, do: status
  defp refusal_status(_failure), do: 401

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp refused(reason), do: {:error, %{reason: reason, source: :wallet_author}}
end

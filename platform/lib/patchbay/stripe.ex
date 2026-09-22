defmodule Patchbay.Stripe do
  @moduledoc """
  The two things Patchbay asks of Stripe for card bundles: a Checkout page for
  one bundle, and a check that an event sent to the webhook was signed by
  Stripe.

  `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` come from the machine's
  environment. A machine started without them sells no bundles.
  """

  @api "https://api.stripe.com/v1"
  @api_version "2026-08-26.dahlia"
  @receive_timeout_ms 15_000

  # How old a signed event may be before it is refused as a replay.
  @tolerance_seconds 300

  @doc "Whether this machine can sell bundles."
  @spec configured?() :: boolean()
  def configured? do
    present?(setting(:secret_key)) and present?(setting(:webhook_secret))
  end

  @doc """
  Opens a Stripe Checkout page selling one bundle of `dollars` to the profile
  `profile_id`, and returns the page's address. Card and Link are the only
  ways to pay, both of which Stripe settles before the page returns.
  """
  @spec create_checkout(Ash.UUID.t(), pos_integer(), %{success: String.t(), cancel: String.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def create_checkout(profile_id, dollars, urls) do
    form = [
      {"mode", "payment"},
      {"payment_method_types[0]", "card"},
      {"payment_method_types[1]", "link"},
      {"line_items[0][quantity]", "1"},
      {"line_items[0][price_data][currency]", "usd"},
      {"line_items[0][price_data][unit_amount]", Integer.to_string(dollars * 100)},
      {"line_items[0][price_data][product_data][name]", "#{dollars} Patchbay Credits"},
      {"client_reference_id", profile_id},
      {"metadata[patchbay_profile_id]", profile_id},
      {"payment_intent_data[metadata][patchbay_profile_id]", profile_id},
      {"success_url", urls.success},
      {"cancel_url", urls.cancel}
    ]

    # The request carries the key, so what went wrong is reduced to a status
    # or a reason before anything is returned or logged.
    case Req.post(@api <> "/checkout/sessions", [form: form] ++ request_options()) do
      {:ok, %Req.Response{status: 200, body: %{"url" => url}}} when is_binary(url) -> {:ok, url}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, _other} -> {:error, :request_failed}
    end
  end

  @doc """
  The event in `raw_body` when `signature_header` (Stripe's
  `Stripe-Signature`) shows Stripe signed exactly those bytes with the
  webhook's secret within the last five minutes.
  """
  @spec verify_event(binary(), String.t() | nil, integer()) :: {:ok, map()} | {:error, :unsigned}
  def verify_event(raw_body, signature_header, now \\ System.system_time(:second)) do
    with {:ok, signed_at, signatures} <- parse_signature(signature_header),
         true <- abs(now - signed_at) <= @tolerance_seconds,
         expected = sign("#{signed_at}.#{raw_body}"),
         true <- Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
         {:ok, event} when is_map(event) <- Jason.decode(raw_body) do
      {:ok, event}
    else
      _unsigned -> {:error, :unsigned}
    end
  end

  @doc "Signs `payload` as Stripe would, with the webhook's secret."
  @spec sign(binary()) :: String.t()
  def sign(payload) do
    :crypto.mac(:hmac, :sha256, setting(:webhook_secret), payload)
    |> Base.encode16(case: :lower)
  end

  defp parse_signature(header) when is_binary(header) do
    parts =
      for part <- String.split(header, ","),
          [key, value] <- [String.split(part, "=", parts: 2)],
          do: {String.trim(key), String.trim(value)}

    with {_t, time} <- List.keyfind(parts, "t", 0),
         {signed_at, ""} <- Integer.parse(time),
         [_ | _] = signatures <- for({"v1", signature} <- parts, do: signature) do
      {:ok, signed_at, signatures}
    end
  end

  defp parse_signature(_header), do: :error

  defp request_options do
    [
      headers: [
        {"authorization", "Bearer " <> setting(:secret_key)},
        {"stripe-version", @api_version}
      ],
      receive_timeout: @receive_timeout_ms,
      retry: false
    ] ++ Application.get_env(:patchbay, :stripe_req_options, [])
  end

  defp setting(key), do: Application.get_env(:patchbay, :stripe, [])[key]

  defp present?(value), do: is_binary(value) and value != ""
end

defmodule Patchbay.Identity.Privy do
  @moduledoc """
  Turns a pair of Privy tokens into the evidence a profile is written from.

  Privy issues two tokens with two different jobs, and Patchbay checks both.
  The access token authenticates the user and names the provider session; the
  identity token carries the signed list of accounts that user has linked. Each
  is verified on its own against Privy's public key, and then the two are bound
  together: they must name the same subject and the same session, and only the
  identity token may carry linked accounts. A browser therefore cannot pair
  somebody else's signed accounts with its own authenticated session.

  A refusal names the boundary that refused it as `{stage, reason}` drawn from
  a fixed vocabulary, so nothing about a token can travel out in a message.
  """

  # The shared verifier's whole documented vocabulary. Anything else is a shape
  # this boundary has never reviewed, so it is reduced rather than repeated.
  @verification_reasons [
    :invalid_verification_key,
    :token_verification_failed,
    :invalid_issuer,
    :invalid_audience,
    :token_expired,
    :token_not_yet_valid,
    :token_issued_in_future,
    :invalid_subject,
    :invalid_linked_accounts,
    :invalid_token
  ]

  @max_display_name_length 80

  @type evidence :: %{
          privy_user_id: String.t(),
          wallet_address: String.t(),
          display_name: String.t()
        }

  @doc """
  Exchanges a verified Privy token pair for the profile evidence it proves.
  """
  @spec verify_session_pair(%{access: String.t(), identity: String.t()}) ::
          {:ok, evidence()} | {:error, {atom(), atom()}}
  def verify_session_pair(%{access: access, identity: identity})
      when is_binary(access) and is_binary(identity) do
    with {:ok, opts} <- verification_options(),
         {:ok, authenticated} <- verify(access, opts, :access_verification),
         {:ok, evidence} <- verify(identity, opts, :identity_verification),
         :ok <- bind(authenticated, evidence),
         {:ok, wallet_address} <- linked_wallet(evidence),
         {:ok, linked_accounts} <- linked_accounts(evidence) do
      {:ok,
       %{
         privy_user_id: evidence.privy_user_id,
         wallet_address: wallet_address,
         display_name: display_name(linked_accounts, evidence.linked_socials, wallet_address)
       }}
    end
  end

  @doc """
  The Privy application the browser signs in against, or `nil` when unset.
  """
  @spec app_id() :: String.t() | nil
  def app_id do
    case Application.get_env(:patchbay, :privy, [])[:app_id] do
      app_id when is_binary(app_id) and app_id != "" -> app_id
      _unset -> nil
    end
  end

  defp verification_options do
    config = Application.get_env(:patchbay, :privy, [])

    case {app_id(), config[:verification_key]} do
      {app_id, key} when is_binary(app_id) and is_binary(key) and key != "" ->
        {:ok, [app_id: app_id, verification_key: key]}

      _unset ->
        {:error, {:configuration, :missing_privy_config}}
    end
  end

  defp verify(token, opts, stage) do
    case RegentPrivy.verify_token(token, opts) do
      {:ok, verified} -> with_session_id(verified, stage)
      {:error, reason} when reason in @verification_reasons -> {:error, {stage, reason}}
      _unreviewed -> {:error, {stage, :unknown_verification_failure}}
    end
  end

  # Only the access token authenticates a provider session, so only it must
  # name one. Privy's identity token carries the signed accounts without a
  # `sid` of its own; whether a session it names anyway is the authenticated
  # one is the binding step's question.
  defp with_session_id(verified, :identity_verification), do: {:ok, verified}

  defp with_session_id(%{claims: %{"sid" => sid}} = verified, :access_verification)
       when is_binary(sid) do
    case String.trim(sid) do
      "" -> {:error, {:access_verification, :missing_session_id}}
      session_id -> {:ok, Map.put(verified, :session_id, session_id)}
    end
  end

  defp with_session_id(_verified, :access_verification),
    do: {:error, {:access_verification, :missing_session_id}}

  # The mismatches are named before the roles, so whatever reaches the role
  # split authenticates this exact subject and this exact session.
  defp bind(%{privy_user_id: subject}, %{privy_user_id: other}) when subject != other,
    do: {:error, {:pair_binding, :subject_mismatch}}

  defp bind(%{session_id: session_id} = authenticated, evidence) do
    if names_session?(evidence.claims, session_id),
      do: bind_roles(authenticated, evidence),
      else: {:error, {:pair_binding, :session_mismatch}}
  end

  # Privy's two token roles are disjoint and the raw claim is what separates
  # them: only an identity token carries `linked_accounts`, and the shared
  # verifier has already refused one that does not decode to a list.
  defp bind_roles(%{claims: authentication}, %{claims: %{"linked_accounts" => accounts}})
       when is_binary(accounts) and not is_map_key(authentication, "linked_accounts"),
       do: :ok

  defp bind_roles(%{claims: %{"linked_accounts" => _accounts}}, _evidence),
    do: {:error, {:pair_binding, :access_role_confused}}

  defp bind_roles(_authenticated, _evidence),
    do: {:error, {:pair_binding, :identity_accounts_missing}}

  # Absence is the identity token's documented shape; a session it does name is
  # normalized exactly like the access token's before comparison.
  defp names_session?(%{"sid" => named}, session_id) when is_binary(named),
    do: String.trim(named) == session_id

  defp names_session?(%{"sid" => _named}, _session_id), do: false
  defp names_session?(_claims, _session_id), do: true

  # A profile is a payment target before it is anything else, so a Privy user
  # with no EVM wallet has nothing to be one with.
  defp linked_wallet(%{wallet_address: address}) when is_binary(address), do: {:ok, address}
  defp linked_wallet(_evidence), do: {:error, {:account_evidence, :missing_linked_wallet}}

  defp linked_accounts(%{claims: %{"linked_accounts" => accounts}}) when is_binary(accounts) do
    case Jason.decode(accounts) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _undecodable -> {:error, {:identity_verification, :invalid_linked_accounts}}
    end
  end

  # Privy's user record rarely carries a name of its own, so one is derived
  # from whatever the signed accounts do carry: the local part of an email
  # first, then a Farcaster or X handle, and failing both the tail of the
  # wallet the tips settle to, which every profile has.
  defp display_name(linked_accounts, linked_socials, wallet_address) do
    from_email =
      Enum.find_value(linked_accounts, fn
        %{"type" => "email", "address" => address} when is_binary(address) ->
          address |> String.split("@") |> List.first() |> presence()

        _other ->
          nil
      end)

    from_social =
      Enum.find_value(linked_socials, fn
        %{provider: provider, username: username} when provider in [:farcaster, :x] ->
          presence(username)

        _other ->
          nil
      end)

    named = from_email || from_social || "agent-" <> String.slice(wallet_address, -6, 6)

    String.slice(named, 0, @max_display_name_length)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end

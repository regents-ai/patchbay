defmodule PatchbayWeb.PrivySessionController do
  @moduledoc """
  The browser session endpoints, as in ash-template: the CSRF bootstrap, the
  Privy sign-in, whether this browser is signed in, sign-out and the browser's
  sign-in failure reports.

  The cookie carries a sign-in lineage, never a profile
  (`Patchbay.Accounts.SessionAuthority`), and only these endpoints write it.
  The browser proves who it is with a pair of Privy tokens and nothing else:
  the access token travels as the bearer and the identity token as Privy's own
  header, so neither reaches a URL, a body or a log.

  Signing in touches only the profile it names. The forum identity the browser
  already carries is kept, because a report filed before signing in was still
  filed by this browser, and so is it when a sign-in is refused or has ended.
  The fixes this browser asked Jev for before signing in are saved to the
  profile, so it keeps every answer Jev gave. Signing out, or signing in to
  another account on the same browser, drops the whole session, so the next
  person to sign in on it starts with nothing of the last one's: not the
  threads they asked, the sites they followed, or the Jev answers they got.
  The person is recorded in their shared Regent account, as on every Regent
  site, so their Points and paired agents follow them here, and given their
  shared profile when they have none, whose public name the Account page saves
  (`PatchbayWeb.Plugs.ProfileOwner`). A suspended person
  is refused (`Patchbay.Identity.AgentProfile.may_act?/1`) and the browser
  stays signed out.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Accounts.SessionAuthority
  alias Patchbay.Assist
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Identity.Privy
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.Plugs.ForumSession
  alias PatchbayWeb.ReadLimit

  require Logger

  @browser_failure_reasons ~w(bridge_startup flow_closed invalid_message provider_error request_timeout session_exchange unable_to_sign)
  @browser_failure_limit 20
  @browser_failure_window_seconds 60

  # Every refusal answers {"error": {"code", "message", "hint"}}, the shape of the
  # site's other JSON errors. The browser reads the code; people read the words.
  @refusals %{
    "unauthorized" => {401, "This sign-in couldn't be confirmed.", "Sign in again."},
    "suspended" =>
      {403, "This account is suspended.", "To ask about it, write to build@regents.sh."},
    "rate_limited" =>
      {429, "Too many new sign-ins came from this address.",
       "Wait the number of seconds in Retry-After, then try again."},
    "session_superseded" =>
      {409, "This browser was signed in again from another tab.", "Reload the page."},
    "session_reset_required" =>
      {409, "This browser's sign-in has ended.", "Reload the page, then sign in again."},
    "account_switch_required" =>
      {409, "This browser was signed in to another account.",
       "Reload the page, then sign in again."},
    "sign_in_unavailable" => {503, "Sign-in isn't available right now.", "Try again in a moment."}
  }

  @doc """
  The browser-session state matrix: a browser with no claim is bootstrapped onto
  a fresh unbound lineage; an exact claim is only observed; a superseded or
  unrecoverable one is told which of the two it is instead of being silently reset.

  Observation writes no session, so this response carries no `Set-Cookie` and a
  delayed one cannot put an older generation back over a later winner's cookie.
  Only a browser carrying no claim can create a lineage, so only that request
  spends the anonymous bootstrap budget, and it spends it before `renew/1` can
  insert a row: a denial leaves behind no lineage and no CSRF session state.
  """
  def csrf(conn, _params), do: admit_bootstrap(conn, claim(conn))

  @doc """
  Records a bounded browser-side Privy failure without accepting provider text,
  identity, wallet, token, signature or exception data. The response is the same
  for valid, invalid and rate-limited reports: diagnostics never steer sign-in.
  """
  def failure(conn, %{"reason" => reason}) when reason in @browser_failure_reasons do
    report_bounded_sign_in_failure(conn, reason)
    diagnostic_accepted(conn)
  end

  def failure(conn, _untrusted_params), do: diagnostic_accepted(conn)

  def create(conn, _untrusted_params) do
    with {:ok, pair} <- session_pair(conn),
         {:ok, evidence} <- Privy.verify_session_pair(pair),
         # Taken before the upsert reads the profile's status, so a suspension
         # saved after that read ends this sign-in (`SessionAuthority`).
         signed_in_at = DateTime.utc_now(),
         {:ok, profile} <- establish(evidence) do
      bind(conn, profile, signed_in_at)
    else
      # The site's own settings are at fault, not this browser's proof: a Privy
      # setting is missing, or the verification key cannot be read. Nothing was
      # judged, so the sign-in the browser holds stays as it is. Revoking it here
      # would sign out every person whose page refreshes while a setting is wrong.
      {:error, {stage, reason}}
      when stage == :configuration or reason == :invalid_verification_key ->
        unavailable(conn, stage, reason)

      {:error, {stage, reason}} ->
        refuse(conn, stage, reason)
    end
  end

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(session_payload(conn.assigns.current_profile))
  end

  def delete(conn, _params) do
    topic = SessionAuthority.revoke(claim(conn))
    conn |> drop_session() |> disconnect_after(topic, &json(&1, %{ok: true}))
  end

  # Logged as an error with its fixed stage and reason, and counted with the
  # refusals, so an operator sees which setting is wrong.
  defp unavailable(conn, stage, reason) do
    Logger.error("Privy sign-in unavailable stage=#{stage} reason=#{reason}")

    :telemetry.execute([:patchbay, :privy, :session_refused], %{count: 1}, %{
      stage: stage,
      reason: reason
    })

    conn |> put_resp_header("cache-control", "no-store") |> refuse("sign_in_unavailable")
  end

  defp admit_bootstrap(conn, nil) do
    budget = Application.fetch_env!(:patchbay, :session_bootstrap_rate_limit)
    window = Keyword.fetch!(budget, :window_seconds)
    {key, source} = ClientAddress.key(conn)

    case ReadLimit.admit({:session_bootstrap, key}, Keyword.fetch!(budget, :limit), window) do
      {:ok, _budget} ->
        renew(conn, nil)

      {:error, :rate_limited, _budget} ->
        :telemetry.execute([:patchbay, :session_bootstrap, :rate_limited], %{count: 1}, %{
          source: source
        })

        conn
        |> put_resp_header("retry-after", to_string(window))
        |> put_resp_header("cache-control", "no-store")
        |> refuse("rate_limited")
    end
  end

  defp admit_bootstrap(conn, claim), do: renew(conn, claim)

  defp renew(conn, claim) do
    case SessionAuthority.renew(claim) do
      {:bootstrap, claim} -> conn |> rotate_session(claim) |> issue_token()
      {:current, _claim} -> issue_token(conn)
      {:error, :superseded} -> refuse(conn, "session_superseded")
      {:error, :reset} -> conn |> rotate_session(nil) |> refuse("session_reset_required")
    end
  end

  defp diagnostic_accepted(conn),
    do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(:no_content, "")

  defp report_bounded_sign_in_failure(conn, reason) do
    {key, _source} = ClientAddress.key(conn)
    bucket = if reason == "flow_closed", do: :retryable, else: :actionable

    with {:ok, _budget} <-
           ReadLimit.admit(
             {:privy_browser_failure, bucket, key},
             @browser_failure_limit,
             @browser_failure_window_seconds
           ) do
      Logger.warning("Privy browser reported sign-in failure reason=#{reason}")
      :telemetry.execute([:patchbay, :privy, :browser_failure], %{count: 1}, %{reason: reason})
    end
  end

  # Privy is verified before the row lock, so only the transition itself is
  # serialized. A different profile is a two-step cutover: this response revokes
  # and disconnects the old lineage and binds nothing.
  defp bind(conn, profile, signed_in_at) do
    case SessionAuthority.sign_in(claim(conn), profile.id, signed_in_at) do
      {:ok, _transition, claim} ->
        :ok = Assist.save_browser_runs(conn.assigns.forum_session_id, profile)
        conn |> rotate_session(claim) |> json(session_payload(profile))

      {:switch, topic} ->
        conn
        |> drop_session()
        |> disconnect_after(topic, &refuse(&1, "account_switch_required"))

      {:error, :superseded} ->
        refuse(conn, "session_superseded")

      {:error, :reset} ->
        conn |> rotate_session(nil) |> refuse("session_reset_required")
    end
  end

  # The profile's own outcomes are named; anything else saving it returns is
  # reduced without being inspected.
  defp establish(evidence) do
    case Identity.upsert_from_privy(evidence) do
      {:ok, profile} -> may_act(profile)
      {:error, _unwritable} -> {:error, {:profile, :not_written}}
    end
  end

  defp may_act(profile) do
    if AgentProfile.may_act?(profile), do: {:ok, profile}, else: {:error, {:profile, :suspended}}
  end

  # Stage and reason are fixed atoms from the classification contract, so they
  # are safe as metric tags and in the message itself; they are never inspected
  # or answered differently, except that a suspended profile is told so. The
  # provider attempt is over before any authority work starts, so no external
  # call sits inside the transaction: a bearer this browser cannot prove revokes
  # the lineage it was offered for instead of leaving it bound and current.
  defp refuse(conn, stage, reason) do
    Logger.info("Privy session refused stage=#{stage} reason=#{reason}")

    :telemetry.execute([:patchbay, :privy, :session_refused], %{count: 1}, %{
      stage: stage,
      reason: reason
    })

    report_bounded_sign_in_failure(conn, "session_exchange")
    topic = SessionAuthority.revoke(claim(conn))
    conn |> rotate_session(nil) |> disconnect_after(topic, &refuse(&1, code(stage, reason)))
  end

  defp code(:profile, :suspended), do: "suspended"
  defp code(_stage, _reason), do: "unauthorized"

  # The answer is sent before the lineage's sockets are told to disconnect, so
  # the browser reads it rather than a dropped connection.
  defp disconnect_after(conn, topic, respond) do
    %Plug.Conn{state: :sent} = conn = respond.(conn)
    if topic, do: PatchbayWeb.Endpoint.broadcast(topic, "disconnect", %{})
    conn
  end

  # Exactly one of each header is a pair. Anything else is refused before Privy
  # is asked anything.
  defp session_pair(conn) do
    with {:ok, access} <- bearer_token(conn),
         {:ok, identity} <- identity_token(conn) do
      {:ok, %{access: access, identity: identity}}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> access] -> present(access, :missing_access_token)
      _absent_or_duplicated -> {:error, {:request_pair, :missing_access_token}}
    end
  end

  defp identity_token(conn) do
    case get_req_header(conn, "privy-id-token") do
      [identity] -> present(identity, :missing_identity_token)
      _absent_or_duplicated -> {:error, {:request_pair, :missing_identity_token}}
    end
  end

  defp present(token, reason) do
    case String.trim(token) do
      "" -> {:error, {:request_pair, reason}}
      token -> {:ok, token}
    end
  end

  defp claim(conn), do: conn |> get_session() |> SessionAuthority.claim()

  # Starts the session over holding `claim`, or no claim at all, and the
  # browser's forum identity, which outlives a sign-in made, refused or ended.
  defp rotate_session(conn, claim) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_forum_session(conn.assigns.forum_session_id)
    |> put_claim(claim)
    |> put_csrf_state()
  end

  defp put_forum_session(conn, nil), do: conn
  defp put_forum_session(conn, id), do: put_session(conn, ForumSession.session_key(), id)

  defp put_claim(conn, nil), do: conn

  defp put_claim(conn, claim) do
    claim
    |> SessionAuthority.session()
    |> Enum.reduce(conn, fn {key, value}, conn -> put_session(conn, key, value) end)
  end

  defp put_csrf_state(conn) do
    Plug.CSRFProtection.get_csrf_token()
    put_session(conn, "_csrf_token", Plug.CSRFProtection.dump_state())
  end

  defp issue_token(conn), do: json(conn, %{csrf_token: Plug.CSRFProtection.get_csrf_token()})

  defp refuse(conn, code) do
    {status, message, hint} = Map.fetch!(@refusals, code)
    conn |> put_status(status) |> json(ApiError.body(code, message, hint))
  end

  defp drop_session(conn), do: configure_session(conn, drop: true)

  defp session_payload(profile), do: %{authenticated: not is_nil(profile)}
end

defmodule PatchbayWeb.PrivySessionController do
  @moduledoc """
  The two requests that start and end a Patchbay sign-in.

  The browser proves who it is with a pair of Privy tokens and nothing else:
  the access token travels as the bearer and the identity token as Privy's own
  header, so neither reaches a URL, a body or a log. What comes back is the
  author object every Patchbay answer names an agent by.

  Signing in touches only the profile it names. The forum identity the browser
  already carries is left where it is, because a report filed before signing in
  was still filed by this browser.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Identity.Privy
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.AuthorJSON
  alias PatchbayWeb.Plugs.CurrentProfile

  require Logger

  # Every way a sign-in is refused: the code, the status it answers with, the
  # words and what to do about it.
  @refusals %{
    "not_configured" =>
      {:service_unavailable, "Signing in is not set up on this Patchbay.",
       "Use Patchbay without signing in."},
    "no_wallet" =>
      {:unprocessable_entity, "Patchbay pays tips straight to a wallet, so signing in needs one.",
       "Add an Ethereum wallet to your Privy account, then sign in again."},
    "unauthorized" => {:unauthorized, "That sign-in could not be verified.", "Sign in again."}
  }

  def create(conn, _untrusted_params) do
    with {:ok, pair} <- session_pair(conn),
         {:ok, evidence} <- Privy.verify_session_pair(pair),
         {:ok, profile} <- Identity.upsert_from_privy(evidence) do
      conn
      |> CurrentProfile.sign_in(profile.id)
      |> json(AuthorJSON.author(profile))
    else
      {:error, {stage, reason}} -> refuse(conn, code(stage, reason))
      {:error, _unwritable} -> refuse(conn, code(:profile, :not_written))
    end
  end

  def delete(conn, _params) do
    conn
    |> CurrentProfile.sign_out()
    |> json(%{signed_out: true})
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

  # A deployment that was never told which Privy application it belongs to says
  # so plainly, because there is nothing the visitor can do about it.
  defp code(:configuration, :missing_privy_config), do: "not_configured"
  defp code(:account_evidence, :missing_linked_wallet), do: "no_wallet"

  # Both values are fixed atoms from the refusal vocabulary, so they belong in
  # the message itself. The browser is told only that it was refused.
  defp code(stage, reason) do
    Logger.debug("Privy sign-in refused stage=#{stage} reason=#{reason}")
    "unauthorized"
  end

  defp refuse(conn, code) do
    {status, message, hint} = Map.fetch!(@refusals, code)

    conn
    |> put_status(status)
    |> json(ApiError.body(code, message, hint))
  end
end

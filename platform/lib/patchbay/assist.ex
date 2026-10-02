defmodule Patchbay.Assist do
  @moduledoc """
  Assists: somebody stuck on a site's tools tells Patchbay what they are
  trying to do, and Patchbay works out the right call for them.

  An agent pays a fixed fee for one in USDC, like every other paid action,
  to the one wallet this Patchbay is set up to take it at. Without that wallet, paid assists answer that they are not set up here
  and nothing else changes. A person at the page gets a few free ones a day,
  counted by `Patchbay.Assist.Allowance`, and pays the same fee after that.
  """

  use Ash.Domain, otp_app: :patchbay

  require Ash.Query

  alias Patchbay.Assist.Run

  resources do
    resource Patchbay.Assist.Run do
      define(:open_run, action: :open)
      define(:get_run, action: :read, get_by: [:id])

      define(:get_open_run_for_payer,
        action: :open_run_for_payer,
        args: [:payer_profile_id],
        get?: true,
        not_found_error?: false
      )

      define(:get_open_run_for_browser,
        action: :open_run_for_browser,
        args: [:browser_session_id],
        get?: true,
        not_found_error?: false
      )

      define(:get_run_as_browser,
        action: :as_browser,
        args: [:id, :browser_session_id],
        get?: true,
        not_found_error?: false
      )

      define(:list_runs_asked_by, action: :asked_by, args: [:payer_profile_id])

      define(:open_free_run, action: :open_free)
      define(:open_agent_free_run, action: :open_agent_free)

      define(:start_run, action: :start)
      define(:record_step, action: :record_step, args: [:step])
      define(:finish_run, action: :finish)
      define(:take_fee, action: :take_fee)
      define(:release_fee, action: :release_fee)
      define(:record_deposited, action: :record_deposited)
      define(:record_fee_failed, action: :record_fee_failed)
      define(:reopen_run, action: :reopen)
    end

    resource Patchbay.Assist.Decision do
      define(:record_decision, action: :record)
      define(:get_decision, action: :read, get_by: [:id], not_found_error?: false)
      define(:report_decision, action: :report, args: [:result])
    end

    resource Patchbay.Assist.ModelCall do
      define(:ask_model, action: :ask)
      define(:ask_model_for_help, action: :ask_for_help)
      define(:close_model_call, action: :answered)
      define(:fail_model_call, action: :failed)
    end
  end

  @doc """
  Opens a free run from the page, its work queued with it: `request` as
  `Patchbay.Assist.Request.draft/1` returned it, under `grant`, for the
  connection `visitor_key` names and the browser `browser_session_id`
  names, asked by the signed-in `actor` if any.
  """
  @spec request_free_run(map(), :visitor | :member, String.t(), Ash.UUID.t(), struct() | nil) ::
          {:ok, Run.t()} | {:error, term()}
  def request_free_run(request, grant, visitor_key, browser_session_id, actor) do
    open_held(fn ->
      open_free_run(
        %{
          request: request,
          grant: grant,
          visitor_key: visitor_key,
          browser_session_id: browser_session_id
        },
        actor: actor
      )
    end)
  end

  @doc """
  Opens a free run for the SIWA-signed `agent`, its work queued with it:
  `request` as `Patchbay.Assist.Request.draft/1` returned it, under one of
  the free fixes its wallet has left today.
  """
  @spec request_agent_free_run(map(), struct()) :: {:ok, Run.t()} | {:error, term()}
  def request_agent_free_run(request, agent) do
    open_held(fn ->
      open_agent_free_run(%{request: request, grant: :agent}, actor: agent)
    end)
  end

  defp open_held(open) do
    Ash.transact(Run, fn ->
      hold_free_fixes()

      with {:ok, run} <- open.(), do: run
    end)
  end

  # Free fixes are counted and the run opened under one lock every free fix
  # takes, held until the opening commits, so requests that arrive together
  # cannot both take the last one, whether it is the connection's, the
  # person's or the site's.
  defp hold_free_fixes do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "patchbay free fixes"
    ])
  end

  @doc """
  Saves every run the browser `browser_session_id` names asked for without
  signing in to `profile`, who has just signed in on it, so the person's
  profile keeps every answer Jev gave them. A browser with no forum identity
  has nothing to save.
  """
  @spec save_browser_runs(Ash.UUID.t() | nil, struct()) :: :ok
  def save_browser_runs(nil, _profile), do: :ok

  def save_browser_runs(browser_session_id, profile) do
    # Sign-in's own write: the browser is known by the identity in its signed
    # cookie and the person by the tokens Privy just verified.
    Patchbay.Assist.Run
    |> Ash.Query.filter(browser_session_id == ^browser_session_id and is_nil(payer_profile_id))
    |> Ash.bulk_update!(:save_to_payer, %{payer_profile_id: profile.id},
      authorize?: false,
      return_records?: false
    )

    :ok
  end

  @doc """
  Hands a run that waited on a person back to Patchbay: the run is reopened
  as paid and the fact is written on it, in one transaction, and its work is
  queued like any other's once both are written. Nothing is paid twice, and
  a fee already forwarded is not forwarded again. A run that is not waiting on a person is left as it is. Run by a
  person at Patchbay from the release's console:

      bin/patchbay rpc 'Patchbay.Assist.rerun("<run id>")'
  """
  @spec rerun(Ash.UUID.t()) :: {:ok, Run.t()} | {:error, term()}
  def rerun(run_id) do
    # A person at Patchbay's console: the run answers to no request.
    Ash.transact(Run, fn ->
      with {:ok, run} <- get_run(run_id, authorize?: false),
           {:ok, reopened} <- reopen_run(run, authorize?: false),
           {:ok, noted} <-
             record_step(reopened, %{"note" => "A person at Patchbay picked this up again."},
               authorize?: false
             ),
           do: noted
    end)
  end

  @doc """
  The wallet a paid assist's fee is paid to, or nil when this Patchbay has
  none set.
  """
  @spec pay_to_address() :: String.t() | nil
  def pay_to_address, do: setting(:pay_to_address)

  @doc """
  The REGENT staking contract each fee is forwarded to as revenue, or nil
  when this Patchbay has none set, in which case fees stay in the wallet
  they were paid to.
  """
  @spec staking_contract_address() :: String.t() | nil
  def staking_contract_address, do: setting(:staking_contract_address)

  defp setting(name) do
    case Application.get_env(:patchbay, :assist, [])[name] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _unset ->
        nil
    end
  end
end

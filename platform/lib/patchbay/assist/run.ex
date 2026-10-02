defmodule Patchbay.Assist.Run do
  @moduledoc """
  One assist: what somebody asked Patchbay to work out on some site, what
  let it open, and what came of it.

  A paid run is opened from the frozen terms of a settled payment and from
  nothing else, so what Patchbay works on is exactly what the payer was
  shown and paid for. A free run is opened from the page, under the free
  fix its connection or its signed-in person had left. A run is read back
  by its payer, or by the browser it was asked from. The status and the
  outcome are the only things that move after it is opened, and every move
  is announced on the run's own channel, so a page watching it follows along.

  The work is a job (`:work`), queued in the same transaction that opens or
  reopens the run, so a run that was paid for is always worked on, after a
  restart too, and on one node only. A run whose work was lost, with its
  node or past its time, is closed as failed by `:close_lost` and never
  worked twice. The fee goes on to the staking contract as a job of its own
  (`:forward_fee`) once the run is answered.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Assist,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshOban]

  alias Patchbay.Assist.Types.DepositStatus
  alias Patchbay.Assist.Types.Grant
  alias Patchbay.Assist.Types.Outcome
  alias Patchbay.Assist.Types.RunStatus
  alias Patchbay.Assist.Types.SignIn

  postgres do
    table("assist_runs")
    repo(Patchbay.Repo)

    identity_wheres_to_sql(
      one_open_run_per_payer: "status IN ('paid', 'running')",
      one_open_run_per_browser: "status IN ('paid', 'running')"
    )
  end

  oban do
    triggers do
      # A paid run is worked on once. A run its job lost stays running and
      # is closed by `:close_lost`, never started again.
      trigger :work do
        action(:work)
        queue(:assist)
        where(expr(status == :paid))
        max_attempts(1)
        timeout(:timer.minutes(5))
        on_error(:interrupt)
        lock_for_update?(false)
        worker_module_name(Patchbay.Assist.Run.Workers.Work)
        scheduler_module_name(Patchbay.Assist.Run.Schedulers.Work)
      end

      # Past the work's own time and Oban's rescue of a dead node's jobs, a
      # run still running has no work behind it.
      trigger :close_lost do
        action(:interrupt)
        queue(:lost_runs)
        where(expr(status == :running and started_at < ago(15, :minute)))
        stream_with(:full_read)
        scheduler_cron("*/5 * * * *")
        worker_module_name(Patchbay.Assist.Run.Workers.CloseLost)
        scheduler_module_name(Patchbay.Assist.Run.Schedulers.CloseLost)
      end

      # A forward that sent nothing is tried again; one that may have sent
      # a deposit is never re-run blind (`Patchbay.Assist.Forward`). The
      # hourly sweep picks up fees left waiting for a staking contract.
      trigger :forward_fee do
        action(:forward_fee)
        queue(:fees)

        where(
          expr(deposit_status == :pending and status in [:finished, :assessment_pending, :failed])
        )

        max_attempts(3)
        on_error(:fee_not_forwarded)
        lock_for_update?(false)
        scheduler_cron("0 * * * *")
        worker_module_name(Patchbay.Assist.Run.Workers.ForwardFee)
        scheduler_module_name(Patchbay.Assist.Run.Schedulers.ForwardFee)
      end
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    # `topic/1` is these same two parts joined the same way, so every change
    # to a run lands on the channel the page watching it listens to.
    publish_all(:update, ["assist:run", :id], transform: &__MODULE__.changed_message/1)
  end

  attributes do
    uuid_primary_key(:id)

    # The profile the run was asked by. It names a row in the identity
    # domain rather than pointing at one, so a run outlives the profile it
    # was bought by. A free run asked without signing in has none.
    attribute(:payer_profile_id, :uuid, allow_nil?: true, public?: true)

    # The browser's forum identity the run was asked under; a wallet author
    # has none.
    attribute(:browser_session_id, :uuid, allow_nil?: true, public?: true)

    attribute(:grant, Grant, allow_nil?: false, public?: true, default: :paid)

    # The key the page door derives for the connection a free run was asked
    # from, which its one free fix a day is counted by. Never the address.
    attribute(:visitor_key, :string, allow_nil?: true, public?: true)

    # The payment that bought a paid run, in the shared payment records; a
    # free run has none.
    attribute(:payment_intent_id, :uuid, allow_nil?: true, public?: true)

    attribute(:goal, :string, allow_nil?: false, public?: true)

    # What went wrong, in the asker's words, when they said.
    attribute(:error, :string, allow_nil?: true, public?: true)
    attribute(:site_url, :string, allow_nil?: false, public?: true)
    attribute(:sign_in, SignIn, allow_nil?: false, public?: true)

    # The calls the agent believed would work, each a tool name and, when
    # the agent knew them, its arguments, in the order the agent gave them.
    attribute(:believed_calls, {:array, :map}, allow_nil?: false, public?: true, default: [])

    attribute(:status, RunStatus, allow_nil?: false, public?: true, default: :paid)
    attribute(:outcome, Outcome, allow_nil?: true, public?: true)

    # What was tried, in order: the tool, its arguments, an excerpt of the
    # site's answer and what Jev made of it.
    attribute(:steps, {:array, :map}, allow_nil?: false, public?: true, default: [])

    attribute(:started_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:finished_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    # Where the fee stands on its way from the operator wallet to the REGENT
    # staking contract, and the deposit's transaction once it is there.
    attribute(:deposit_status, DepositStatus, allow_nil?: false, public?: true, default: :pending)
    attribute(:deposit_tx_hash, :string, allow_nil?: true, public?: true)

    timestamps()
  end

  identities do
    # One payment buys one run; a second opening of the same payment is
    # refused by the database rather than by a check a retry could race past.
    identity(:one_run_per_payment, [:payment_intent_id], eager_check?: false)

    # One open run per payer: the check made before anyone pays is repeated
    # by the database when the run is opened, so two payments settling at
    # once still open one run now and the other on a later call.
    identity(:one_open_run_per_payer, [:payer_profile_id],
      where: expr(status in [:paid, :running]),
      eager_check?: false
    )

    # One open run per browser, the same way: a page may not ask for a
    # second fix while its first is still being worked on.
    identity(:one_open_run_per_browser, [:browser_session_id],
      where: expr(status in [:paid, :running]),
      eager_check?: false
    )
  end

  actions do
    defaults([:read])

    read :open_runs do
      description("Every run that is paid for and not yet answered.")
      filter(expr(status in [:paid, :running]))
    end

    read :open_run_for_payer do
      description("The run that is paid for and not yet answered for one payer, if any.")
      argument(:payer_profile_id, :uuid, allow_nil?: false)

      filter(expr(status in [:paid, :running] and payer_profile_id == ^arg(:payer_profile_id)))
    end

    read :open_run_for_browser do
      description("The run not yet answered that one browser asked for, if any.")
      argument(:browser_session_id, :uuid, allow_nil?: false)

      filter(
        expr(status in [:paid, :running] and browser_session_id == ^arg(:browser_session_id))
      )
    end

    read :asked_by do
      description("Every run one person asked for, newest first.")
      argument(:payer_profile_id, :uuid, allow_nil?: false)

      filter(expr(payer_profile_id == ^arg(:payer_profile_id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :as_browser do
      description("""
      One run as the browser that asked for it reads it. The browser is known
      by the identity in its signed cookie and by nothing it sends, so the
      filter is the whole check.
      """)

      argument(:id, :uuid, allow_nil?: false)
      argument(:browser_session_id, :uuid, allow_nil?: false)

      filter(expr(id == ^arg(:id) and browser_session_id == ^arg(:browser_session_id)))
    end

    create :open do
      description("""
      Opens the run a settled payment bought, from that payment's frozen terms:
      the request as the payer wrote it, under the id the terms named.
      """)

      accept([])

      argument(:intent, :struct,
        allow_nil?: false,
        constraints: [instance_of: RegentPayments.PaymentIntent],
        description: "The settled payment for this assist, as it stands."
      )

      argument(:browser_session_id, :uuid,
        allow_nil?: true,
        description: "The browser's forum identity the settling request carried, if any."
      )

      change(set_attribute(:payer_profile_id, actor(:id)))
      change(set_attribute(:browser_session_id, arg(:browser_session_id)))
      change(Patchbay.Assist.Changes.OpenFromIntent)
      change(run_oban_trigger(:work))
    end

    create :open_free do
      description("""
      Opens a free run from the page, from a request the door already checked,
      under the free fix the connection or the signed-in person has left.
      """)

      accept([])

      argument(:request, :map,
        allow_nil?: false,
        description: "The request as `Patchbay.Assist.Request.draft/1` returned it."
      )

      argument(:grant, Grant, allow_nil?: false)
      argument(:visitor_key, :string, allow_nil?: false)
      argument(:browser_session_id, :uuid, allow_nil?: false)

      validate(one_of(:grant, [:visitor, :member]), message: "must be visitor or member")
      change(Patchbay.Assist.Changes.OpenFree)
      change(run_oban_trigger(:work))
    end

    create :open_agent_free do
      description("""
      Opens a free run for an agent signed in with SIWA, from a request the
      door already checked, under the free fixes its wallet has left today.
      """)

      accept([])

      argument(:request, :map,
        allow_nil?: false,
        description: "The request as `Patchbay.Assist.Request.draft/1` returned it."
      )

      argument(:grant, Grant, allow_nil?: false)

      validate(one_of(:grant, [:agent]), message: "must be agent")
      change(Patchbay.Assist.Changes.OpenFree)
      change(run_oban_trigger(:work))
    end

    update :work do
      description("""
      Works a paid run through to its answer: starts it, tries what fits, and
      closes it. The calls go out to other sites and to models, so nothing
      here holds a transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Assist.Work)
    end

    update :start do
      description("Patchbay picks a paid run up and starts working on it.")
      accept([])
      validate(attribute_equals(:status, :paid), message: "is not waiting to be started")
      change(set_attribute(:status, :running))
      change(set_attribute(:started_at, &DateTime.utc_now/0))
    end

    update :record_step do
      description("Writes down one more thing Patchbay tried or found, after the ones before it.")
      require_atomic?(false)
      accept([])
      argument(:step, :map, allow_nil?: false)
      change(Patchbay.Assist.Changes.AppendStep)
    end

    update :finish do
      description("Closes the run with what it found, or with why it stopped.")
      require_atomic?(false)
      accept([:status, :outcome])
      validate(Patchbay.Assist.Validations.UnderWay)

      validate(one_of(:status, [:finished, :assessment_pending, :failed]),
        message: "must be finished, assessment_pending or failed"
      )

      change(set_attribute(:finished_at, &DateTime.utc_now/0))
      change(run_oban_trigger(:forward_fee), where: [attribute_equals(:deposit_status, :pending)])
    end

    update :save_to_payer do
      description("""
      Saves a run a browser asked for before signing in to the person who has
      since signed in on that browser.
      """)

      accept([])
      argument(:payer_profile_id, :uuid, allow_nil?: false)
      change(set_attribute(:payer_profile_id, arg(:payer_profile_id)))
    end

    update :forward_fee do
      description("""
      Hands the run's fee on to the REGENT staking contract and writes down
      what came of it. The deposit goes out to Base, so nothing here holds a
      transaction open.
      """)

      accept([])
      transaction?(false)
      require_atomic?(false)
      manual(Patchbay.Assist.Forward)
    end

    update :take_fee do
      description("""
      Takes the one forward of a fee still waiting, before anything is sent,
      so however often its job runs, one fee is forwarded once.
      """)

      accept([])

      # A validation, not a filter: this atomic update checks it inside the
      # UPDATE statement against the stored value, while Ash 3.33 leaves an
      # action's `filter` change out of the statement.
      validate(attribute_equals(:deposit_status, :pending),
        message: "is not waiting to be forwarded"
      )

      change(set_attribute(:deposit_status, :forwarding))
    end

    update :release_fee do
      description("Puts back a fee whose forward sent nothing, to be forwarded again.")
      accept([])
      validate(attribute_equals(:deposit_status, :forwarding), message: "is not being forwarded")
      change(set_attribute(:deposit_status, :pending))
    end

    update :record_deposited do
      description("The fee's deposit is on Base, in the transaction named.")
      accept([:deposit_tx_hash])
      validate(attribute_equals(:deposit_status, :forwarding), message: "is not being forwarded")
      change(set_attribute(:deposit_status, :deposited))
    end

    update :record_fee_failed do
      description("""
      The fee's forward did not go through; the deposit's transaction, when
      one was sent, is named for a person to look up on the chain.
      """)

      accept([:deposit_tx_hash])
      validate(attribute_equals(:deposit_status, :forwarding), message: "is not being forwarded")
      change(set_attribute(:deposit_status, :failed))
    end

    update :fee_not_forwarded do
      description("A fee whose forward sent nothing on every try, left for a person.")
      accept([])
      change(set_attribute(:deposit_status, :failed))
    end

    update :reopen do
      description("""
      Hands a run that waited on a person back to Patchbay as a paid run it
      picks up again: what was tried stays written, and nothing is paid twice.
      """)

      accept([])

      validate(attribute_equals(:status, :assessment_pending),
        message: "is not waiting on a person"
      )

      change(set_attribute(:status, :paid))
      change(set_attribute(:outcome, nil))
      change(set_attribute(:finished_at, nil))
      change(run_oban_trigger(:work))
    end

    update :interrupt do
      description("""
      Marks an open run whose work was lost, with its node, past its time or
      on an error, as failed: its calls are not made twice, and a person
      looks at it.
      """)

      accept([])
      validate(attribute_in(:status, [:paid, :running]), message: "is not open")
      change(set_attribute(:status, :failed))
      change(set_attribute(:finished_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # Only the settled payment's own payer opens its run, and only the
    # purchase process holds a settled intent to open one from. A free run
    # opens for anyone at the page, under the grant the allowance gives
    # right now and no other, and for a SIWA-signed agent under its own. The
    # actions that move a run along (`work`, `start`, `record_step`, `finish`,
    # `interrupt`, the fee's `forward_fee`, `take_fee`, `release_fee`,
    # `record_deposited`, `record_fee_failed` and `fee_not_forwarded`, and
    # `reopen`) and
    # `save_to_payer` are named by no policy, so nothing that arrives over
    # HTTP can reach them; Patchbay's own jobs, sign-in, and a person at its
    # console are their only callers and say so by skipping authorization
    # deliberately.
    policy action(:open) do
      authorize_if(actor_present())
    end

    policy action(:open_free) do
      authorize_if(Patchbay.Assist.Checks.WithinAllowance)
    end

    policy action(:open_agent_free) do
      authorize_if(Patchbay.Assist.Checks.WithinAgentAllowance)
    end

    # The browser's read filters on the identity in its own signed cookie,
    # so it is authorized as a whole and the filter does the choosing.
    bypass action(:as_browser) do
      authorize_if(always())
    end

    # Every other read is the payer's own. Without an actor there is no
    # payer to match, and a run asked for without signing in is not
    # everybody's to read.
    policy action_type(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(payer_profile_id == ^actor(:id)))
    end
  end

  @doc "The channel a run's changes are announced on."
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(run_id), do: "assist:run:#{run_id}"

  @doc false
  @spec changed_message(Ash.Notifier.Notification.t()) :: {:assist_run_changed, Ash.UUID.t()}
  def changed_message(%Ash.Notifier.Notification{data: %{id: id}}),
    do: {:assist_run_changed, id}
end

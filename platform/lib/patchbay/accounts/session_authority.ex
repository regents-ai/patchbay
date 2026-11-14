defmodule Patchbay.Accounts.SessionAuthority do
  @moduledoc """
  The durable authority behind one browser session lineage, as in ash-template.

  The signed cookie carries a random 32-byte lineage, its generation and the
  socket topic the lineage determines, never a profile: who is signed in comes
  from the row, keyed by the lineage's SHA-256 digest so a database reader
  cannot rebuild a cookie. `/auth/csrf` commits an unbound generation-zero row;
  the first bind and every same-profile refresh advance the generation once, so
  the previous cookie is stale everywhere. Revocation is terminal, and a sign-in
  lapses the cookie's `max_age` (30 days) after it was made: refreshes keep it
  current until then, never beyond. Every transition inserts the row when
  absent, locks it `FOR UPDATE` and applies at most one change in one
  transaction, so the absent-row and present-row races serialize identically.

  A bound row names an agent profile, and it signs that profile in only while
  the profile may act (`Patchbay.Identity.AgentProfile.may_act?/1`) and the
  sign-in was made after the profile's last suspension. A sign-in a suspension
  ended never holds again: signing in once more on the same browser revokes it,
  and the browser binds a fresh lineage.

  A row no browser can still hold is deleted once a day (`prune/0`, run by
  `Patchbay.Accounts.SessionPruner`): one untouched for a day longer than the
  cookie lives. By then an unbound row's cookie has run out, a bound one's
  sign-in has lapsed, and a revoked one was revoked at least that long ago. A
  copy of such a cookie kept past its time finds no row and is refused, or, for
  a never-signed-in one, starts again signed out.
  """

  use Ash.Resource,
    domain: Patchbay.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Repo

  @actor %{role: :system}
  @lineage_bytes 32
  @maximum_generation 9_223_372_036_854_775_807
  @canonical_keys ["session_lineage", "session_generation", "live_socket_id"]
  @sign_in_lifetime_seconds Application.compile_env!(:patchbay, :sign_in_lifetime_seconds)

  @typedoc "Everything a browser carries. There is no profile here by design."
  @type claim :: %{lineage: String.t(), generation: non_neg_integer()}

  postgres do
    table("session_authorities")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:generation, "session_authorities_generation_nonnegative",
        check: "generation >= 0",
        message: "generation must be nonnegative"
      )

      check_constraint(:signed_in_at, "session_authorities_signed_in_when_bound",
        check: "(agent_profile_id IS NULL) = (signed_in_at IS NULL)",
        message: "a bound sign-in records when it was made"
      )
    end

    references do
      reference(:agent_profile, on_delete: :restrict)
    end

    # The daily prune finds rows by when they were last touched.
    custom_indexes do
      index([:updated_at], concurrently: true)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:lineage_digest, :binary, allow_nil?: false, sensitive?: true)
    attribute(:generation, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:revoked_at, :utc_datetime_usec)
    # When the verified sign-in that bound this lineage began: taken before the
    # sign-in read the profile's status, so a suspension saved after that read
    # ends it (`after_cutoff?/2`).
    attribute(:signed_in_at, :utc_datetime_usec)
    timestamps()
  end

  relationships do
    belongs_to(:agent_profile, AgentProfile)
  end

  identities do
    identity(:unique_lineage_digest, [:lineage_digest])
  end

  actions do
    # The primary read is what an atomic update re-reads the locked row through.
    defaults([:read])

    read :by_lineage_digest do
      get?(true)
      argument(:lineage_digest, :binary, allow_nil?: false)
      filter(expr(lineage_digest == ^arg(:lineage_digest)))
    end

    create :mint do
      accept([:lineage_digest])
    end

    update :bind do
      accept([])
      argument(:profile_id, :uuid, allow_nil?: false)
      argument(:signed_in_at, :utc_datetime_usec, allow_nil?: false)
      validate(absent([:revoked_at, :agent_profile_id]))
      change(set_attribute(:agent_profile_id, arg(:profile_id)))
      change(set_attribute(:signed_in_at, arg(:signed_in_at)))
      change(atomic_update(:generation, expr(generation + 1)))
    end

    # Refresh cannot name a profile, so a bound lineage can never change one.
    update :advance do
      accept([])
      validate(absent(:revoked_at))
      validate(present(:agent_profile_id))
      change(atomic_update(:generation, expr(generation + 1)))
    end

    update :revoke do
      accept([])
      validate(absent(:revoked_at))
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end

    # Only `prune/0` uses it, on rows no browser can still hold.
    destroy(:prune)
  end

  policies do
    policy always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  @doc """
  Deletes every row untouched for a day longer than the cookie lives, in one
  statement that returns nothing.
  """
  @spec prune() :: :ok | {:error, term()}
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -(@sign_in_lifetime_seconds + 86_400), :second)

    __MODULE__
    |> Ash.Query.filter(updated_at < ^cutoff)
    |> Ash.bulk_destroy(:prune, %{},
      actor: @actor,
      strategy: :atomic,
      return_errors?: true,
      return_records?: false,
      notify?: false
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc """
  The claim `session` carries, or `nil` when it carries none the server minted:
  the exact unpadded base64url encoding of 32 bytes, a generation inside the
  column's range and the socket topic this lineage determines. Anything else is
  malformed, never a weaker claim.
  """
  @spec claim(map() | nil) :: claim() | nil
  def claim(%{"session_lineage" => lineage, "session_generation" => generation} = session)
      when is_binary(lineage) and is_integer(generation) and
             generation in 0..@maximum_generation//1 do
    with {:ok, <<raw::binary-size(@lineage_bytes)>>} <- Base.url_decode64(lineage, padding: false),
         ^lineage <- Base.url_encode64(raw, padding: false),
         true <- Map.get(session, "live_socket_id") == topic(lineage) do
      %{lineage: lineage, generation: generation}
    else
      _malformed -> nil
    end
  end

  def claim(_session), do: nil

  @doc "Whether `session` states a claim at all; a malformed one is refused, not read as none."
  @spec claim_shaped?(map() | nil) :: boolean()
  def claim_shaped?(session) when is_map(session),
    do: Enum.any?(@canonical_keys, &Map.has_key?(session, &1))

  def claim_shaped?(_session), do: false

  @doc "The canonical claim fields, and only those, that a response restores."
  @spec session(claim()) :: %{String.t() => term()}
  def session(%{lineage: lineage, generation: generation}),
    do: %{
      "session_lineage" => lineage,
      "session_generation" => generation,
      "live_socket_id" => topic(lineage)
    }

  @doc """
  The `/auth/csrf` state matrix. A claim above generation zero whose row is
  absent fails closed and reports the breach without the identifying lineage.
  """
  @spec renew(claim() | nil) :: {:bootstrap | :current, claim()} | {:error, :superseded | :reset}
  def renew(nil) do
    lineage = @lineage_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Ash.create!(__MODULE__, %{lineage_digest: digest(lineage)}, action: :mint, actor: @actor)
    {:bootstrap, %{lineage: lineage, generation: 0}}
  end

  def renew(%{lineage: lineage, generation: generation} = claim) do
    case locked(claim, &{state(&1, claim), &1}) do
      {:exact, row} -> {:current, claim_at(lineage, row)}
      {:superseded, _row} -> {:error, :superseded}
      {:reset, nil} -> absent_row(generation)
      {:reset, _row} -> {:error, :reset}
    end
  end

  @doc """
  The one serialized transition a verified sign-in performs: an exact unbound
  claim binds the profile from `signed_in_at`, an exact claim of the same
  profile refreshes, and a different profile revokes the old lineage so a later
  request binds a fresh one. A same-profile sign-in that a suspension ended is
  revoked and answered `{:error, :reset}`, so the browser binds a fresh one too.
  """
  @spec sign_in(claim() | nil, Ecto.UUID.t(), DateTime.t()) ::
          {:ok, :bind | :refresh, claim()}
          | {:switch, String.t()}
          | {:error, :superseded | :reset}
  def sign_in(%{lineage: lineage} = claim, profile_id, signed_in_at) do
    locked(claim, fn row ->
      case state(row, claim) do
        :exact -> transition(row, lineage, profile_id, signed_in_at)
        other -> {:error, other}
      end
    end)
  end

  def sign_in(nil, _profile_id, _signed_in_at), do: {:error, :reset}

  @doc "Revokes a lineage terminally, ensuring an unseen one first; returns its socket topic."
  @spec revoke(claim() | nil) :: String.t() | nil
  def revoke(%{lineage: lineage}) do
    {:ok, _row} =
      Ash.transact(__MODULE__, fn ->
        ensure(lineage, DateTime.utc_now())
        lineage |> lock() |> revoke!()
      end)

    topic(lineage)
  end

  def revoke(nil), do: nil

  @doc """
  The lineage and signed-in profile an exactly current claim resolves to, and
  the instant that sign-in lapses: `{nil, nil, nil}` when the claim is not
  current, `{lineage, nil, nil}` when it is but no one has signed in on it, and
  `{lineage, nil, lapses_at}` when the profile it signed in may no longer act or
  a suspension ended the sign-in.
  """
  @spec resolve(claim() | nil) ::
          {String.t() | nil, AgentProfile.t() | nil, DateTime.t() | nil}
  def resolve(%{lineage: lineage} = claim) do
    row = row(lineage)

    case state(row, claim) do
      :exact -> {lineage, verified(row), lapses_at(row)}
      :ensurable -> {lineage, nil, nil}
      _lifecycle -> {nil, nil, nil}
    end
  end

  def resolve(nil), do: {nil, nil, nil}

  @doc """
  The profile a mounted lease still signs in, or `nil`. A refresh advances the
  generation beneath a mounted socket, so a lease revalidates the lineage,
  profile, revocation, sign-in age and the profile's standing instead.
  """
  @spec leased_profile(String.t(), Ecto.UUID.t()) :: AgentProfile.t() | nil
  def leased_profile(lineage, profile_id) do
    row = row(lineage)

    if match?(%{revoked_at: nil, agent_profile_id: ^profile_id}, row) and not lapsed?(row),
      do: verified(row)
  end

  @doc "The deterministic, lineage-stable topic every socket for a lineage mounts on."
  @spec topic(String.t()) :: String.t()
  def topic(lineage),
    do: "session_authority:" <> Base.url_encode64(digest(lineage), padding: false)

  # The four states an integrity-valid claim can hold against its row. A claim
  # ahead of its row, or above generation zero without one, is unrecoverable
  # rather than merely superseded, and so is a sign-in past its lifetime.
  defp state(nil, %{generation: 0}), do: :ensurable
  defp state(nil, _claim), do: :reset
  defp state(%{revoked_at: revoked_at}, _claim) when not is_nil(revoked_at), do: :reset

  defp state(%{generation: generation} = row, %{generation: claimed}) do
    cond do
      lapsed?(row) -> :reset
      claimed == generation -> :exact
      claimed < generation -> :superseded
      true -> :reset
    end
  end

  # A sign-in lasts from the bind that made it; a refresh never extends it. An
  # unbound row confers nothing, so it has no lifetime to outlive.
  defp lapsed?(%{signed_in_at: nil}), do: false
  defp lapsed?(row), do: not DateTime.before?(DateTime.utc_now(), lapses_at(row))

  defp lapses_at(%{signed_in_at: nil}), do: nil

  defp lapses_at(%{signed_in_at: signed_in_at}),
    do: DateTime.add(signed_in_at, @sign_in_lifetime_seconds)

  # Exhaustion is terminal rather than wrapping: the lineage is revoked and the
  # browser bootstraps a fresh one.
  defp transition(%{generation: @maximum_generation} = row, _lineage, _profile_id, _at) do
    revoke!(row)
    {:error, :reset}
  end

  defp transition(%{agent_profile_id: nil} = row, lineage, profile_id, signed_in_at) do
    input = %{profile_id: profile_id, signed_in_at: signed_in_at}
    {:ok, :bind, updated_claim(row, lineage, :bind, input)}
  end

  defp transition(%{agent_profile_id: profile_id} = row, lineage, profile_id, _at) do
    if verified(row) do
      {:ok, :refresh, updated_claim(row, lineage, :advance, %{})}
    else
      revoke!(row)
      {:error, :reset}
    end
  end

  defp transition(row, lineage, _other_profile_id, _at) do
    revoke!(row)
    {:switch, topic(lineage)}
  end

  defp updated_claim(row, lineage, action, input),
    do: claim_at(lineage, Ash.update!(row, input, action: action, actor: @actor))

  defp revoke!(%{revoked_at: nil} = row),
    do: Ash.update!(row, %{}, action: :revoke, actor: @actor)

  defp revoke!(terminal), do: terminal

  # Bind and refresh may ensure the unbound generation-zero row the claim names,
  # so the absent-row order of a race takes the same lock as the present-row one.
  # `Ash.transact` sends what the updates inside notify once it commits. A
  # refused transition still commits what it wrote (the seeded row, or a
  # revocation before it answers `{:error, :reset}`), so its answer is wrapped:
  # `Ash.transact` rolls back an `{:error, _}` returned as is.
  defp locked(%{lineage: lineage, generation: generation}, callback) do
    {:ok, {:committed, result}} =
      Ash.transact(__MODULE__, fn ->
        if generation == 0, do: ensure(lineage, nil)
        {:committed, lineage |> lock() |> callback.()}
      end)

    result
  end

  # Ash is bypassed on purpose: the seed confers nothing until a locked
  # transition binds it, and the loser of a concurrent seed must fall through to
  # that lock silently, which `on_conflict: :nothing` is.
  defp ensure(lineage, revoked_at) do
    now = DateTime.utc_now()

    row = %{
      id: Ash.UUID.generate(),
      lineage_digest: digest(lineage),
      generation: 0,
      revoked_at: revoked_at,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(__MODULE__, [row], on_conflict: :nothing, conflict_target: :lineage_digest)
  end

  defp absent_row(generation) do
    :telemetry.execute([:patchbay, :session_authority, :absent_row], %{count: 1}, %{
      generation: generation
    })

    {:error, :reset}
  end

  defp lock(lineage),
    do: lineage |> lookup() |> Ash.Query.lock(:for_update) |> Ash.read_one!()

  defp row(lineage), do: lineage |> lookup() |> Ash.read_one!()

  defp lookup(lineage) do
    Ash.Query.for_read(__MODULE__, :by_lineage_digest, %{lineage_digest: digest(lineage)},
      actor: @actor
    )
  end

  # Only a person who signed in with Privy is signed in by a browser; an agent's
  # own wallet author never is, as only a human account is in ash-template. A
  # profile the database is too busy to read is never taken for one that may
  # not act: the read raises, the page answers busy, and the sign-in still holds
  # when it is opened again.
  defp verified(%{agent_profile_id: nil}), do: nil

  defp verified(%{agent_profile_id: id, signed_in_at: signed_in_at}) do
    case Identity.get_profile!(id, load: [:wallet_addresses]) do
      %{authentication_origin: :privy} = profile ->
        if AgentProfile.may_act?(profile) and after_cutoff?(profile, signed_in_at), do: profile

      _wallet_author ->
        nil
    end
  end

  # The cut-off is the second the database's clock is in as the suspension
  # writes the profile (`AgentProfile`'s `suspend`). A sign-in's time is taken
  # before it reads the profile's status (`PatchbayWeb.PrivySessionController`),
  # and a read that saw the profile active came before the suspension's write:
  # each waits for the other while it holds the row. So the sign-in's second is
  # no later than the cut-off, and ending every sign-in up to the cut-off, its
  # own second included, ends it. This assumes the web machines' clocks and the
  # database's agree to within a second: a web clock running ahead by part of a
  # second could let a sign-in made up to that part of a second before the
  # suspension outlive it. A sign-in after a reinstatement in the cut-off's own
  # second is ended too; signing in again in the next second holds.
  defp after_cutoff?(%{sessions_valid_after: nil}, _signed_in_at), do: true

  defp after_cutoff?(%{sessions_valid_after: cutoff}, signed_in_at),
    do: DateTime.to_unix(signed_in_at) > DateTime.to_unix(cutoff)

  defp claim_at(lineage, %{generation: generation}),
    do: %{lineage: lineage, generation: generation}

  defp digest(lineage), do: :crypto.hash(:sha256, lineage)
end

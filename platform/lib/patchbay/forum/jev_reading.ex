defmodule Patchbay.Forum.JevReading do
  @moduledoc """
  What Jev made of one paid priority report.

  Jev is a classifier: it answers typed questions about a report and nothing
  else. A reading holds those answers so the thread can say in one line what
  kind of help the report asks for and how complete its steps are. It sorts and
  highlights only. Who wrote a report, where its money stands and whether it is
  settled are never read from here.

  One row stands for one report, and a report is read once.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Forum.Types.JevKind

  @detail_labels ["no steps", "partial steps", "reproducible steps"]

  postgres do
    table("forum_jev_readings")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    # The model that answered, as the provider named it, so a reading can be
    # traced to the version that made it.
    attribute(:model, :string, allow_nil?: false, public?: true)

    attribute(:kind, JevKind, allow_nil?: false, public?: true)

    attribute :kind_confidence, :float do
      allow_nil?(false)
      public?(true)
      constraints(min: 0.0, max: 1.0)
    end

    # Where the report's steps sit on `detail_labels/0`, from 0 to its last index.
    attribute :detail_score, :float do
      allow_nil?(false)
      public?(true)
      constraints(min: 0.0, max: 2.0)
    end

    create_timestamp(:inserted_at)
  end

  identities do
    # A second reading of the same report is refused by the database rather
    # than by a check the worker could race past.
    identity(:unique_report, [:report_id], eager_check?: false)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :record do
      description("Writes down Jev's answers about one report.")
      accept([:report_id, :model, :kind, :kind_confidence, :detail_score])
    end
  end

  policies do
    # A reading is as public as the report it is about. `record` is named by no
    # policy, so nothing that arrives over HTTP can reach it; Patchbay's reader
    # is the only caller and says so by skipping authorization deliberately.
    policy action_type(:read) do
      authorize_if(expr(report.visibility == :published))
    end
  end

  @doc "The ordered labels Jev scores a report's steps against."
  @spec detail_labels() :: [String.t()]
  def detail_labels, do: @detail_labels
end

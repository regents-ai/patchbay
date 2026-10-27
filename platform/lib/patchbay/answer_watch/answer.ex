defmodule Patchbay.AnswerWatch.Answer do
  @moduledoc """
  One engine's answer to one tracked question in one week: the answer's
  words, the addresses it cites, and whether it links Patchbay (cites an
  address on patchbay.help) or names it. The question's persona, stage and
  topic are copied in when the answer is written, so later edits to the
  question list never change what an earlier week recorded.

  Every write is Patchbay's own and says so by skipping authorization; no
  visitor reads these rows except through the admin download.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.AnswerWatch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.AnswerWatch.Questions

  postgres do
    table("answer_watch_answers")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    # The Monday (UTC) of the week the answer was asked in.
    attribute(:week, :date, allow_nil?: false, public?: true)

    attribute(:engine, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:chatgpt, :perplexity]]
    )

    attribute(:question, :string, allow_nil?: false, public?: true)

    attribute(:persona, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Questions.personas()]
    )

    attribute(:stage, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Questions.stages()]
    )

    attribute(:topic, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Questions.topics()]
    )

    # The model that answered, as the provider named it.
    attribute(:model, :string, allow_nil?: false, public?: true)
    attribute(:answer, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:cited_urls, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:patchbay_cited, :boolean, allow_nil?: false, public?: true)
    attribute(:patchbay_mentioned, :boolean, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:once_a_week, [:week, :engine, :question])
  end

  actions do
    defaults([:read])

    create :record do
      description("One engine's answer to one tracked question, for the week it was asked in.")

      accept([
        :week,
        :engine,
        :question,
        :persona,
        :stage,
        :topic,
        :model,
        :answer,
        :cited_urls,
        :patchbay_cited,
        :patchbay_mentioned
      ])
    end
  end

  policies do
    # No visitor reads or writes these; Patchbay's own work skips this.
    policy always() do
      forbid_if(always())
    end
  end
end

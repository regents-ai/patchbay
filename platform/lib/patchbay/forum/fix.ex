defmodule Patchbay.Forum.Fix do
  @moduledoc """
  A fix, written down as fields on the reply that gives it: the software it
  is for, the exact versions it was tried on or that carry it, the versions
  the problem affects,
  whether it is a confirmed fix, an interim step or not proven, the change to
  make, how to test it and what the test shows, what it does not cover, the
  sources it rests on, and dated notes on what became known when. It is
  written once, with the reply, like the reply's words. An agent
  that finds the reply by its software and version reads the change and the
  test without parsing anyone's prose.

  It is the writer's own account, the same as the reply's words: Patchbay
  does not run the test. Whether it worked for others is what they say with
  `record_answer_use`.
  """

  use Ash.Resource, data_layer: :embedded

  @max_name 80
  @max_version 40
  @max_affected 200
  @max_text 2_000
  @max_link 500
  @max_sources 10
  @max_versions 10
  @max_updates 20
  @statuses [:confirmed_fix, :interim_mitigation, :not_proven]
  @texts [:software, :affected_versions, :change, :test, :result, :not_covered]
  # Every field the reading is shown (`words/1`), lists included: each is
  # cleaned and checked for a wallet's secret the same way.
  @written @texts ++ [:versions, :sources, :updates]

  attributes do
    attribute :software, :string do
      description("The package, tool or service the fix is for, e.g. castore.")
      allow_nil?(false)
      public?(true)
      constraints(max_length: @max_name)
    end

    attribute :versions, {:array, :string} do
      description("""
      Each exact version it was tried on or that carries it, e.g. 1.0.22: one
      version to an item, so a search for any one of them finds the fix.
      """)

      allow_nil?(false)
      default([])
      public?(true)

      constraints(
        max_length: @max_versions,
        items: [max_length: @max_version, match: ~r/\A\S+\z/]
      )
    end

    attribute :affected_versions, :string do
      description("Which versions have the problem, e.g. PHP 5.4 and later.")
      allow_nil?(true)
      public?(true)
      constraints(max_length: @max_affected)
    end

    attribute :status, :atom do
      description("""
      confirmed_fix (it fixes the problem), interim_mitigation (a step to take
      until there is a fix) or not_proven (nobody has shown it helps yet).
      """)

      allow_nil?(false)
      public?(true)
      constraints(one_of: @statuses)
    end

    attribute :change, :string do
      description("What to change.")
      allow_nil?(false)
      public?(true)
      constraints(max_length: @max_text, trim?: false)
    end

    attribute :test, :string do
      description("How to test the change, such as a command to run.")
      allow_nil?(false)
      public?(true)
      constraints(max_length: @max_text, trim?: false)
    end

    attribute :result, :string do
      description("What the test showed, or what it should show.")
      allow_nil?(false)
      public?(true)
      constraints(max_length: @max_text, trim?: false)
    end

    attribute :not_covered, :string do
      description("What this does not cover, and measures that probably do not help.")
      allow_nil?(true)
      public?(true)
      constraints(max_length: @max_text, trim?: false)
    end

    # Each a link a reader can open as it is
    # (`Patchbay.Forum.Validations.SourceLinks`).
    attribute :sources, {:array, :string} do
      description("""
      Links to what the fix rests on: each https or http with a host, no
      user name or password, and no spaces or < > " '.
      """)

      allow_nil?(false)
      default([])
      public?(true)
      constraints(max_length: @max_sources, items: [max_length: @max_link])
    end

    attribute :updates, {:array, :map} do
      description("""
      Dated notes the writer gives with the fix, oldest first: each the moment
      something became known (UTC, not in the future) and what it was.
      """)

      allow_nil?(false)
      default([])
      public?(true)

      constraints(
        max_length: @max_updates,
        items: [
          fields: [
            at: [type: :utc_datetime, allow_nil?: false],
            text: [type: :string, allow_nil?: false, constraints: [max_length: 500]]
          ]
        ]
      )
    end
  end

  actions do
    defaults([
      :read,
      create: [
        :software,
        :versions,
        :affected_versions,
        :status,
        :change,
        :test,
        :result,
        :not_covered,
        :sources,
        :updates
      ]
    ])
  end

  changes do
    change({Patchbay.Forum.Changes.StripControlCharacters, attributes: @written}, on: [:create])
  end

  # Public for good, like the reply around it.
  validations do
    validate({Patchbay.Forum.Validations.NoWalletSecret, attributes: @written}, on: [:create])
    validate({Patchbay.Forum.Validations.SourceLinks, attribute: :sources}, on: [:create])
    validate({Patchbay.Forum.Validations.NoFutureUpdates, attribute: :updates}, on: [:create])
  end

  @text_fields Enum.map(@texts, &Atom.to_string/1) ++ ["status"]

  @doc """
  Whether a fix as sent has the shape it is read in: text under the text
  fields and `status`, a list of versions under `versions`, a list of links
  under `sources`, and a list of
  `{at, text}` under `updates`. What each value may be is the resource's to
  say when the reply is written.
  """
  @spec shape?(term()) :: boolean()
  def shape?(fix) when is_map(fix) do
    Enum.all?(fix, fn
      {field, value} when field in @text_fields ->
        is_binary(value)

      {field, texts} when field in ["versions", "sources"] ->
        is_list(texts) and Enum.all?(texts, &is_binary/1)

      {"updates", updates} ->
        is_list(updates) and Enum.all?(updates, &update?/1)

      _other ->
        false
    end)
  end

  def shape?(_other), do: false

  defp update?(%{"at" => at, "text" => text} = update) when map_size(update) == 2,
    do: is_binary(at) and is_binary(text)

  defp update?(_other), do: false

  @doc """
  A fix as it was sent, as one block of words, for the reading every post
  gets before it is published. Fields left out say nothing.
  """
  @spec words(map() | nil) :: String.t()
  def words(nil), do: ""

  def words(fix) do
    texts =
      @text_fields
      |> Enum.reject(&(fix[&1] in [nil, ""]))
      |> Enum.map(&(String.capitalize(&1) <> ": " <> fix[&1]))

    versions = Enum.map(fix["versions"] || [], &("Version: " <> &1))
    sources = Enum.map(fix["sources"] || [], &("Source: " <> &1))
    updates = Enum.map(fix["updates"] || [], &("Update " <> &1["at"] <> ": " <> &1["text"]))

    Enum.join(texts ++ versions ++ sources ++ updates, "\n")
  end

  @doc "What a fix is for, as the page names it: the software and its versions."
  @spec named_for(t()) :: String.t()
  def named_for(%{software: software, versions: []}), do: software

  def named_for(%{software: software, versions: versions}),
    do: software <> " " <> Enum.join(versions, ", ")

  @doc "A fix's status in a few words, as the page shows it."
  @spec status_label(atom()) :: String.t()
  def status_label(:confirmed_fix), do: "Confirmed fix"
  def status_label(:interim_mitigation), do: "Interim step"
  def status_label(:not_proven), do: "Not proven"
end

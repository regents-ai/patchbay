defmodule Patchbay.Forum.FindText do
  @moduledoc """
  The site and tool matches (`:find` on `Patchbay.Forum.Site` and
  `Patchbay.Forum.Tool`): a row whose `contains` attributes hold the typed
  `:text` in any case, or whose `near` attributes nearly match it (a letter or
  two wrong).

  Every condition is one a trigram index on its attribute answers, so a match
  never reads the whole table: the words are matched with `ILIKE`, `%` and `_`
  taken as themselves, and the near match with `<%`.
  """

  use Ash.Resource.Preparation

  import Ash.Expr

  @impl Ash.Resource.Preparation
  def prepare(query, options, _context) do
    text = Ash.Query.get_argument(query, :text)
    words = Ash.CiString.new(text)

    conditions =
      Enum.map(options[:contains], &expr(contains(^ref(&1), ^words))) ++
        Enum.map(options[:near], &expr(fragment("? OPERATOR(public.<%) ?", ^text, ^ref(&1))))

    Ash.Query.filter(query, ^Enum.reduce(conditions, &expr(^&2 or ^&1)))
  end
end

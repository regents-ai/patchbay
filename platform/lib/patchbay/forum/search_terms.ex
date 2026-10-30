defmodule Patchbay.Forum.SearchTerms do
  @moduledoc """
  The words a visitor typed, as a full-text query for the words a search reads
  (`search_vector` on a thread, its site, a reply or a card): every word
  (`search_terms(term, :all)`) or any one of them (`search_terms(term, :any)`).

  PostgreSQL reads the typed words as it reads a place's own (`to_tsvector`):
  stemmed, stop words dropped, and an address such as `example.com` kept whole.
  The query is built from those words themselves, each quoted, so nothing typed
  is ever read as a query operator. The last word typed may be half written, so
  it is found at the start of a word: "pay" finds "payment"; "ment" does not.
  Only when it has three letters or more and is not a number: "1", "500" or the
  "3" of "tool_3" would otherwise find every number that starts with it. Every
  other word is found whole.
  """

  use Ash.CustomExpression,
    name: :search_terms,
    arguments: [[:string, :atom]]

  # A word's place counts the stop words before it, so the last word typed is
  # the one at the last place of the words as typed (`'simple'`, which keeps
  # them); a stop word typed last leaves no word to find by its start.
  @words """
  ARRAY(
    SELECT quote_literal(lexeme) ||
      CASE WHEN at = (SELECT max(p) FROM unnest(to_tsvector('simple', ?)), unnest(positions) p)
        AND length(lexeme) >= 3 AND lexeme !~ '^[0-9]+$'
      THEN ':*' ELSE '' END
    FROM (SELECT lexeme, positions[array_length(positions, 1)] AS at
          FROM unnest(to_tsvector('english', ?))) typed
  )
  """
  @all "array_to_string(#{@words}, ' & ')::tsquery"
  @any "array_to_string(#{@words}, ' | ')::tsquery"

  @impl Ash.CustomExpression
  # Ash takes a fragment's text only as written out, so it is put in here.
  def expression(AshPostgres.DataLayer, [term, :all]),
    do: {:ok, expr(fragment(unquote(@all), ^term, ^term))}

  def expression(AshPostgres.DataLayer, [term, :any]),
    do: {:ok, expr(fragment(unquote(@any), ^term, ^term))}

  def expression(_data_layer, _arguments), do: :unknown
end

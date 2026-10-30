defmodule Patchbay.Forum.SearchTerms do
  @moduledoc """
  The words a visitor typed, as a full-text query for the words a search reads
  (`search_vector` on a thread, its site, a reply or a card): every word
  (`search_terms(term, :all)`) or any one of them (`search_terms(term, :any)`).

  PostgreSQL reads the typed words as it reads stored ones (`to_tsvector`):
  stemmed, stop words dropped, and an address such as `example.com` kept whole.
  The query is built from those words themselves, each quoted, so nothing typed
  is ever read as a query operator.
  """

  use Ash.CustomExpression,
    name: :search_terms,
    arguments: [[:string, :atom]]

  @all "array_to_string(ARRAY(SELECT quote_literal(lexeme) FROM unnest(to_tsvector('english', ?))), ' & ')::tsquery"
  @any "array_to_string(ARRAY(SELECT quote_literal(lexeme) FROM unnest(to_tsvector('english', ?))), ' | ')::tsquery"

  @impl Ash.CustomExpression
  # Ash takes a fragment's text only as written out, so it is put in here.
  def expression(AshPostgres.DataLayer, [term, :all]),
    do: {:ok, expr(fragment(unquote(@all), ^term))}

  def expression(AshPostgres.DataLayer, [term, :any]),
    do: {:ok, expr(fragment(unquote(@any), ^term))}

  def expression(_data_layer, _arguments), do: :unknown
end

defmodule PatchbayWeb.AnswerWatchController do
  @moduledoc """
  The weekly answer check as a spreadsheet, for Credits admins only
  (`PatchbayWeb.ErrorsAdmin` turns everyone else away): one row per engine,
  question and week, newest week first, with who asks, how far along they
  are, the topic, whether the answer links or names Patchbay, the addresses
  it cites and the answer itself.
  """

  use PatchbayWeb, :controller

  alias Patchbay.AnswerWatch

  @columns ~w(week engine persona stage topic question patchbay_cited patchbay_mentioned cited_urls model answer)a

  def index(conn, _params) do
    answers =
      AnswerWatch.list_answers!(
        query: Ash.Query.sort(AnswerWatch.Answer, week: :desc, engine: :asc, inserted_at: :asc),
        # The admin's own download; ErrorsAdmin has already checked who asks.
        authorize?: false
      )

    rows = [Enum.map(@columns, &Atom.to_string/1) | Enum.map(answers, &row/1)]

    send_download(conn, {:binary, Enum.map_join(rows, "", &line/1)},
      filename: "patchbay-ai-answers.csv",
      content_type: "text/csv"
    )
  end

  defp row(answer) do
    Enum.map(@columns, fn
      :cited_urls -> Enum.join(answer.cited_urls, " ")
      column -> to_string(Map.fetch!(answer, column))
    end)
  end

  defp line(cells), do: Enum.map_join(cells, ",", &cell/1) <> "\r\n"

  # Every cell is quoted. A cell that a spreadsheet would read as a formula
  # starts with an apostrophe, since the answers are other services' words.
  defp cell(value) do
    value = if String.starts_with?(value, ["=", "+", "-", "@"]), do: "'" <> value, else: value
    ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")
  end
end

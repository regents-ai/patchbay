defmodule Patchbay.AnswerWatch do
  @moduledoc """
  The weekly answer check: what ChatGPT and Perplexity answer when asked the
  questions Patchbay should be the answer to, and whether they name or link
  Patchbay.

  The questions are kept in code (`Patchbay.AnswerWatch.Questions`). Once a
  week each is put to each engine with web search on
  (`Patchbay.AnswerWatch.WeeklyRun`), and every answer is written down with
  the addresses it cites (`Patchbay.AnswerWatch.Answer`). Admins download the
  answers as a spreadsheet at /admin/ai-answers.csv.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.AnswerWatch.Answer do
      define(:record_answer, action: :record)
      define(:list_answers, action: :read)
    end
  end
end

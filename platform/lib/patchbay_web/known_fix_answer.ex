defmodule PatchbayWeb.KnownFixAnswer do
  @moduledoc """
  What Jev's look at the known fixes came to as a fix's first step, as the
  fix's page, its answer and the run's read show it, and an agent's word on
  whether the fix worked (`report_known_fix`).

  The answer is one of three: a known fix to try, one detail to find and ask
  again with, or that none of the known fixes matches. A fix's record can
  also name a fix Patchbay has since taken out.
  How sure Jev was is shown as its judgement. What is known of a fix keeps
  three things apart: Patchbay tried it itself, agents said it worked or did
  not, or it is only suggested.
  """

  alias Patchbay.Assist
  alias Patchbay.Assist.KnownFix
  alias Patchbay.Assist.KnownFixes
  alias Patchbay.Assist.KnownFixPick
  alias Patchbay.Assist.Run
  alias Patchbay.Forum.Origin
  alias PatchbayWeb.ApiError

  @type kind :: :known_fix | :needs_detail | :none_fits | :withdrawn
  @type t :: %{
          answer: kind(),
          site: String.t() | nil,
          decision_id: String.t() | nil,
          jev_match: float() | nil,
          title: String.t() | nil,
          fix: KnownFix.t() | nil,
          reports: KnownFixPick.reports() | nil
        }

  @doc """
  An agent's word on the decision `id`: `worked` or `did_not_work`, taken
  once. The refusal carries the HTTP status it answers with.
  """
  @spec report(term(), term()) :: {:ok, map()} | {:error, {atom(), map()}}
  def report(id, result, actor \\ nil)

  def report(id, result, actor) when result in ["worked", "did_not_work"] do
    # Finding the decision by the id the agent holds is Patchbay's own read;
    # the report itself is authorized by holding that id.
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, %{} = decision} <- Assist.get_decision(uuid, authorize?: false) do
      case Assist.report_decision(decision, String.to_existing_atom(result),
             actor: actor || %{role: :fix_page, decision_id: uuid}
           ) do
        {:ok, decision} ->
          {:ok,
           %{recorded: true, decision_id: decision.id, result: Atom.to_string(decision.result)}}

        {:error, %Ash.Error.Invalid{errors: [%{field: :reported_at}]}} ->
          {:error,
           {:conflict,
            ApiError.body(
              "already_reported",
              "You already reported on this fix; your first report stands.",
              "Nothing more to do."
            )}}

        {:error, _} ->
          {:error,
           {:forbidden,
            ApiError.body(
              "not_authorized",
              "This report is not authorized.",
              "Retry with current pairing and fresh proof."
            )}}
      end
    else
      _missing ->
        {:error,
         {:not_found,
          ApiError.body(
            "not_found",
            "There is no known-fix answer with that decision_id.",
            "Use the decision_id the answer gave you, unchanged."
          )}}
    end
  end

  def report(_id, _result, _actor),
    do:
      {:error,
       {:unprocessable_entity, ApiError.invalid(["result: must be worked or did_not_work"])}}

  @doc "What was said of the decision `id`, `worked` or `did_not_work`, or nil before a report."
  @spec reported(String.t()) :: String.t() | nil
  def reported(id) do
    # Patchbay's own read of the decision its own record names.
    case Assist.get_decision(id, authorize?: false) do
      {:ok, %{result: result}} when not is_nil(result) -> Atom.to_string(result)
      {:ok, _unreported} -> nil
    end
  end

  @doc """
  The answer Jev's look wrote down as the run's first step, as the fix
  shows it, or nil before Jev has looked or when the site has no fixes.
  """
  @spec for_run(Run.t()) :: t() | nil
  def for_run(%Run{} = run) do
    case looked(run) do
      %{"decision_id" => id, "fix" => choice, "confidence" => confidence} ->
        {:ok, site} = Origin.normalize(run.site_url)
        picked(site, id, choice, confidence, KnownFixes.get(choice))

      nil ->
        nil
    end
  end

  @doc "What Jev's look on the run came to, without what agents said of it."
  @spec kind(Run.t()) :: kind() | nil
  def kind(%Run{} = run) do
    case looked(run) do
      %{"fix" => choice} -> kind(choice, KnownFixes.get(choice))
      nil -> nil
    end
  end

  defp looked(run) do
    Enum.find_value(run.steps, fn step -> is_map(step["known_fix"]) && step["known_fix"] end)
  end

  defp picked(site, id, choice, confidence, fix) do
    %{
      empty(site)
      | answer: kind(choice, fix),
        decision_id: id,
        jev_match: confidence,
        title: fix && fix.title,
        fix: fix,
        reports: fix && KnownFixPick.reports(fix.id)
    }
  end

  defp empty(site) do
    %{
      answer: nil,
      site: site,
      decision_id: nil,
      jev_match: nil,
      title: nil,
      fix: nil,
      reports: nil
    }
  end

  defp kind("none_fits", nil), do: :none_fits
  defp kind(_id, nil), do: :withdrawn
  defp kind(_id, %KnownFix{kind: :question}), do: :needs_detail
  defp kind(_id, _fix), do: :known_fix

  @doc "The answer as JSON-ready fields, for the run's read."
  @spec json(t()) :: map()
  def json(%{answer: :withdrawn} = answer) do
    %{answer: "withdrawn", site: answer.site, decision_id: answer.decision_id, why: withdrawn()}
  end

  def json(%{answer: :none_fits} = answer) do
    %{
      answer: "none_fits",
      site: answer.site,
      decision_id: answer.decision_id,
      jev_match: answer.jev_match,
      next: none_fits_next(answer.site)
    }
  end

  def json(%{fix: %KnownFix{} = fix} = answer) do
    %{
      answer: Atom.to_string(answer.answer),
      site: answer.site,
      decision_id: answer.decision_id,
      jev_match: answer.jev_match,
      fix_id: fix.id,
      title: fix.title,
      applies_when: fix.applies_when,
      does_not_apply_when: fix.does_not_apply_when,
      steps: fix.steps,
      caveats: fix.caveats,
      evidence: %{
        checked_by_patchbay_on: fix.checked && Date.to_iso8601(fix.checked),
        agents_said_it_worked: answer.reports.worked,
        agents_said_it_did_not_work: answer.reports.did_not_work,
        in_words: evidence(answer)
      }
    }
    |> Map.merge(report_with(answer))
  end

  @doc "The answer as Markdown, for a fix's answer."
  @spec markdown(t()) :: String.t()
  def markdown(%{answer: :withdrawn}), do: withdrawn()

  def markdown(%{answer: :none_fits} = answer) do
    "Jev looked through the fixes Patchbay knows for #{answer.site} and none matches. " <>
      "Jev's match: #{match(answer)}. #{none_fits_next(answer.site)}"
  end

  def markdown(%{fix: %KnownFix{} = fix} = answer) do
    [
      "**#{heading(answer)}: #{fix.title}**",
      "Jev's match: #{match(answer)}. #{evidence(answer)}",
      "When it applies:",
      fix.applies_when,
      "Not when:",
      fix.does_not_apply_when,
      "Steps:",
      fix.steps,
      "Caveats:",
      fix.caveats
    ]
    |> Kernel.++(report_line(answer))
    |> Enum.join("\n\n")
  end

  @doc "The heading a known fix or a detail to find goes under."
  @spec heading(t()) :: String.t()
  def heading(%{answer: :needs_detail}), do: "Jev needs one more detail"
  def heading(%{answer: _known_fix}), do: "Known fix"

  @doc "How sure Jev was, as the judgement it is."
  @spec match(t()) :: String.t()
  def match(%{jev_match: confidence}),
    do: "#{round(confidence * 100)}% sure (a judgement, not a check)"

  @doc "What is known of the fix, in one sentence or two."
  @spec evidence(t()) :: String.t()
  def evidence(%{fix: %KnownFix{kind: :question}}),
    do: "A detail to find, from Patchbay's own notes."

  def evidence(%{fix: %KnownFix{checked: checked}, reports: reports}) do
    [checked_words(checked), report_words(reports)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Suggested from Patchbay's own notes; no agent has said yet whether it worked."
      known -> Enum.join(known, " ")
    end
  end

  defp checked_words(nil), do: nil

  defp checked_words(date),
    do: "Patchbay tried this fix itself on #{Calendar.strftime(date, "%-d %B %Y")}."

  defp report_words(%{worked: 0, did_not_work: 0}), do: nil

  defp report_words(%{worked: worked, did_not_work: did_not_work}),
    do:
      "Agents' own word: #{agents(worked)} said it worked, #{agents(did_not_work)} said it did not."

  defp agents(1), do: "1 agent"
  defp agents(count), do: "#{count} agents"

  # Only a fix can be said to have worked; a detail to find is asked again with.
  defp report_line(%{answer: :known_fix} = answer) do
    [
      "Say whether it worked: call `report_known_fix` with " <>
        ~s({"decision_id": "#{answer.decision_id}", "result": "worked"}) <>
        ", or `did_not_work`."
    ]
  end

  defp report_line(_detail), do: []

  defp report_with(%{answer: :known_fix}),
    do: %{
      report_with:
        "Once you have tried it, call report_known_fix with this decision_id and result worked or did_not_work."
    }

  defp report_with(_detail), do: %{}

  defp none_fits_next(site),
    do:
      "Ask other agents with ask_question, naming #{site}, what you were trying to do and the exact error."

  defp withdrawn, do: "Jev chose a known fix that Patchbay has since taken out."
end

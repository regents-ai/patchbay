defmodule PatchbayWeb.KnownFixAnswer do
  @moduledoc """
  What Jev's look at the known fixes comes to, in the same words on every
  door: the help page for a site, `find_known_fix` on the page, the hosted
  tools and HTTP, and a fix's answer.

  The answer is one of four: a known fix to try, one detail to find and ask
  again with, that none of the known fixes matches, or why Jev did not look.
  A fix's record can also name a fix Patchbay has since taken out.
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

  @max_goal_chars 1_000
  @max_error_chars 4_000

  @type kind :: :known_fix | :needs_detail | :none_fits | :withdrawn | :not_looked_up
  @type t :: %{
          answer: kind(),
          site: String.t() | nil,
          decision_id: String.t() | nil,
          jev_match: float() | nil,
          title: String.t() | nil,
          fix: KnownFix.t() | nil,
          reports: KnownFixPick.reports() | nil,
          why: String.t() | nil
        }

  @doc """
  The free look for `params` (`site`, and `goal` or `error` in the agent's
  words) from the connection `visitor_key` names, or the refusal of params
  that break the rules.
  """
  @spec look_up(map(), String.t()) :: {:ok, t()} | {:error, map()}
  def look_up(params, visitor_key) do
    with {:ok, site} <- site(params["site"]),
         {:ok, goal} <- words("goal", params["goal"], @max_goal_chars),
         {:ok, error} <- words("error", params["error"], @max_error_chars) do
      ask = %{site: site, goal: goal, error: error, tools: []}
      {:ok, from_pick(KnownFixPick.for_help(ask, visitor_key), site)}
    end
  end

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
              "Nothing more to do. A new answer from find_known_fix takes a new report."
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

  @doc "The answer for one pick for the site `site`."
  @spec from_pick(KnownFixPick.pick(), String.t()) :: t()
  def from_pick({:picked, decision, fix}, site) do
    picked(site, decision.id, decision.choice, decision.confidence, fix)
  end

  def from_pick({:not_picked, reason}, site) do
    %{empty(site) | answer: :not_looked_up, why: why(reason, site)}
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
      reports: nil,
      why: nil
    }
  end

  defp kind("none_fits", nil), do: :none_fits
  defp kind(_id, nil), do: :withdrawn
  defp kind(_id, %KnownFix{kind: :question}), do: :needs_detail
  defp kind(_id, _fix), do: :known_fix

  @doc "The answer as JSON-ready fields, for the tools and HTTP."
  @spec json(t()) :: map()
  def json(%{answer: :not_looked_up} = answer) do
    %{answer: "not_looked_up", site: answer.site, why: answer.why}
  end

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

  @doc "The answer as Markdown, for the help page and a fix's answer."
  @spec markdown(t()) :: String.t()
  def markdown(%{answer: :not_looked_up} = answer), do: answer.why
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

  defp why(:no_known_fixes, site), do: "Patchbay knows no fixes for #{site} yet."

  defp why(:nothing_to_match, _site),
    do: "Say what you were trying to do or what went wrong, and Jev looks for a known fix."

  defp why(:used_up, _site),
    do: "Jev's free look-ups for known fixes are used for today. They start again tomorrow."

  defp why(:unavailable, _site), do: "Jev could not look just now. Try again in a moment."

  defp site(value) do
    case Origin.normalize(value) do
      {:ok, site} -> {:ok, site}
      {:error, message} -> {:error, ApiError.invalid(["site: #{message}"])}
    end
  end

  defp words(_field, nil, _max), do: {:ok, nil}

  defp words(field, value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.valid?(trimmed) and String.length(trimmed) <= max -> {:ok, trimmed}
      true -> {:error, ApiError.invalid(["#{field}: must be text of at most #{max} characters"])}
    end
  end

  defp words(field, _value, max),
    do: {:error, ApiError.invalid(["#{field}: must be text of at most #{max} characters"])}
end

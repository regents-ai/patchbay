defmodule PatchbayWeb.FixLive.Show do
  @moduledoc """
  One fix as it happens. The page opens on the run the browser asked for,
  or the signed-in person paid for, follows every step Patchbay writes on it
  the moment it is written, and ends with the answer in a form an agent can
  be handed. Nothing on this page changes the run; whoever reads it can say
  whether the known fix Jev matched worked.
  """

  use PatchbayWeb, :live_view

  alias Patchbay.Assist
  alias Patchbay.Assist.Receipt
  alias Patchbay.Assist.Run
  alias PatchbayWeb.FixLive.Panel
  alias PatchbayWeb.KnownFixAnswer
  alias PatchbayWeb.Motion

  import PatchbayWeb.Forum.BoardHTML, only: [markdown_html: 1]

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case find(id, session, socket.assigns.current_profile) do
      {:ok, run} ->
        {:ok, follow(socket, run)}

      :none ->
        {:ok,
         socket
         |> put_flash(:error, "There is no fix to show at that address.")
         |> redirect(to: ~p"/")}
    end
  end

  # The run changed: it is read again as it stands now.
  @impl true
  def handle_info({:assist_run_changed, id}, %{assigns: %{run: %Run{id: id}}} = socket) do
    {:noreply, show(socket, reread(id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The word goes on the decision this run's own record names, never on an
  # id the page sends.
  @impl true
  def handle_event("report_known_fix", %{"result" => result}, socket) do
    case KnownFixAnswer.report(socket.assigns.known_fix.decision_id, result) do
      {:ok, _recorded} ->
        {:noreply, socket |> assign(reported: result) |> show(socket.assigns.run)}

      # Said already, from another tab: the word that stands is shown.
      {:error, {:conflict, _refusal}} ->
        {:noreply,
         assign(socket, reported: KnownFixAnswer.reported(socket.assigns.known_fix.decision_id))}
    end
  end

  # A connected page listens first and reads the run again after, so a
  # change written in between is on the page rather than missed.
  defp follow(socket, run) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Run.topic(run.id))
      show(socket, reread(run.id))
    else
      show(socket, run)
    end
  end

  defp reread(id) do
    # The page was granted this run when it opened, so the re-read is
    # Patchbay's own.
    {:ok, run} = Assist.get_run(id, authorize?: false)
    run
  end

  defp show(socket, run) do
    known_fix = KnownFixAnswer.for_run(run)
    headline = Panel.headline(run)
    host = URI.parse(run.site_url).host

    socket
    |> assign_new(:reported, fn -> known_fix && KnownFixAnswer.reported(known_fix.decision_id) end)
    |> assign(
      run: run,
      page_title: headline,
      page_description: "How Patchbay worked out a fix for an agent stuck on #{host}.",
      headline: headline,
      working?: Panel.working?(run),
      lines: Panel.lines(run),
      known_fix: known_fix,
      answer: Panel.answer(run, known_fix, url(~p"/fixes/#{run.id}")),
      receipt: Receipt.for_run(run),
      host: host
    )
  end

  # The receipt's lines, in the page's words.
  defp payment_line(%{paid: false}), do: "Free"

  defp payment_line(%{paid: true} = paid) do
    [
      paid.amount_usdc && "#{paid.amount_usdc} USDC",
      paid.wallet && "from #{paid.wallet}",
      paid.transaction && "transaction #{paid.transaction}"
    ]
    |> joined("Paid")
  end

  defp model_line(nil), do: "No draft"

  defp model_line(draft) do
    [
      provider_name(draft.provider),
      draft.model,
      draft.prompt_tokens && "#{draft.prompt_tokens} tokens in, #{draft.completion_tokens} out",
      draft.response_id && "answer #{draft.response_id}",
      draft.request_id && "request #{draft.request_id}",
      draft.outcome == :failed && "no answer"
    ]
    |> joined("")
  end

  defp provider_name("near_ai"), do: "NEAR AI"
  defp provider_name("openrouter"), do: "OpenRouter"
  defp provider_name(nil), do: nil

  defp suggested_line(%{known_fix: title, call: call}) do
    [title && "Known fix: #{title}", call && call_words(call)]
    |> joined("None")
  end

  defp call_words(call) do
    "#{call.tool} #{Jason.encode!(call.arguments || %{})}, " <>
      if(call.called_by_patchbay, do: "called by Patchbay", else: "not called")
  end

  defp result_line("passed"), do: "Passed, as the agent reported"
  defp result_line("failed"), do: "Failed, as the agent reported"
  defp result_line("not_reported"), do: "Not reported"

  defp joined(parts, empty) do
    case Enum.filter(parts, &is_binary/1) do
      [] -> empty
      kept -> Enum.join(kept, " · ")
    end
  end

  # The browser's own run, by the identity in its signed cookie; or the
  # signed-in person's, by their profile. Anyone else is sent to the front.
  defp find(id, session, profile) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         nil <- as_browser(uuid, session["forum_session_id"]),
         nil <- as_payer(uuid, profile) do
      :none
    else
      %Run{} = run -> {:ok, run}
      :error -> :none
    end
  end

  defp as_browser(uuid, browser_session_id) when is_binary(browser_session_id) do
    case Assist.get_run_as_browser(uuid, browser_session_id) do
      {:ok, run} -> run
      {:error, _unreadable} -> nil
    end
  end

  defp as_browser(_uuid, _no_session), do: nil

  defp as_payer(_uuid, nil), do: nil

  defp as_payer(uuid, profile) do
    case Assist.get_run(uuid, actor: profile, not_found_error?: false) do
      {:ok, run} -> run
      {:error, _forbidden} -> nil
    end
  end
end

defmodule Patchbay.Identity.DisconnectApps do
  @moduledoc """
  Disconnects every app a suspended person has connected
  (`Patchbay.OAuth.disconnect_apps/1`), so none of them works again after the
  person is reinstated. The suspension queues it in its own transaction
  (`Patchbay.Identity.Changes.QueueDisconnectApps`).

  While connected apps are switched off the job waits a minute and looks
  again, without using an attempt, so it runs within about a minute of them
  being switched on. Until it runs, the suspension alone already refuses
  every app, because each app request asks whether the person may act.

  It disconnects the apps connected when it runs. A person reinstated before
  it runs and who connects an app again in between may find that app
  disconnected too; they connect it once more. One job for each person while
  it is waiting or running, so suspending again in that time adds nothing. A
  database error is tried again, up to 20 attempts.
  """
  use Oban.Worker,
    queue: :connected_apps,
    max_attempts: 20,
    unique: [keys: [:profile_id], period: :infinity, states: :incomplete]

  alias Patchbay.Identity

  @looks_again_s 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    if RegentOAuth.enabled?() do
      profile_id
      |> Identity.get_profile!(actor: %{role: :system})
      |> Patchbay.OAuth.disconnect_apps()
    else
      {:snooze, @looks_again_s}
    end
  end
end

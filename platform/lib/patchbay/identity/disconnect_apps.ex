defmodule Patchbay.Identity.DisconnectApps do
  @moduledoc """
  Disconnects every app a suspended person has connected
  (`Patchbay.OAuth.disconnect_apps/1`), so none of them works again after the
  person is reinstated. The suspension queues it in its own transaction
  (`Patchbay.Identity.Changes.QueueDisconnectApps`).

  Its queue, `connected_apps`, starts paused while connected apps are switched
  off (config/runtime.exs), so the job waits, without running, for a boot that
  switches them on. Oban starts before the endpoint, so the job runs as that
  boot begins serving. Until it has finished, an app the person connected
  before the suspension is refused while they stay suspended, because each
  app request asks whether they may act, but answered again once they are
  reinstated.

  It disconnects the apps connected when it runs. A person reinstated before
  it runs and who connects an app again in between finds that app
  disconnected too; they connect it once more. One job for each person while
  it waits or runs, so suspending again in that time adds nothing, and
  running it twice disconnects nothing more.

  A failure is tried again, up to 20 attempts over about twelve days. After the
  last one Oban discards the job: the error tracker at /admin/errors shows it
  with the job's id, except a last attempt that found no database connection,
  which is only logged. The person's apps stay refused for as long as the
  suspension lasts. Before reinstating them, the console runs the job again
  (`Oban.retry_job/1` with that id, in HANDOFF.md) and reinstates once it has
  finished.
  """
  use Oban.Worker,
    queue: :connected_apps,
    max_attempts: 20,
    unique: [keys: [:profile_id], period: :infinity, states: :incomplete]

  alias Patchbay.Identity

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    profile_id
    |> Identity.get_profile!(actor: %{role: :system})
    |> Patchbay.OAuth.disconnect_apps()
  end
end

defmodule PatchbayWeb.PublicationAuthorizationHTML do
  use PatchbayWeb, :html

  def index(assigns) do
    ~H"""
    <main class="patchbay-shell">
      <Regent.Structure.panel>
        <h1>Public posting permissions</h1>
        <p>
          Delegate free PUBLIC greetings, questions, replies and outcomes to an agent wallet. Nothing here permits payments, priority, payouts, moderation, secrets or private support. Each request still needs the agent's wallet proof.
        </p>
        <p :if={@notice} role="alert">{@notice}</p>
        <p :if={!@current_profile}>
          Sign in through <a href="/profile">your profile</a> to approve and manage permissions.
        </p>
        <.form :if={@current_profile} for={@form} action="/publication-authorizations" method="post">
          <p :if={@form.source.errors != []} role="alert">
            Check the wallet, scope, expiry and public confirmation. No permission was created.
          </p>
          <Regent.Primitives.field label="Agent wallet (Base address)" id="grant_subject_wallet">
            <input
              id="grant_subject_wallet"
              name="grant[subject_wallet]"
              value={@form[:subject_wallet].value}
              required
              pattern="0x[0-9a-fA-F]{40}"
            />
          </Regent.Primitives.field>
          <Regent.Primitives.field label="Task or goal (no private details)" id="grant_purpose">
            <input
              id="grant_purpose"
              name="grant[purpose]"
              value={@form[:purpose].value}
              required
              maxlength="200"
            />
          </Regent.Primitives.field>
          <Regent.Primitives.field label="Duration" id="grant_mode">
            <select id="grant_mode" name="grant[mode]" required>
              <option value="time" selected={to_string(@form[:mode].value) == "time"}>
                Until the expiry below
              </option>
              <option value="task" selected={to_string(@form[:mode].value) == "task"}>
                One task, until I mark complete or revoke
              </option>
              <option value="goal" selected={to_string(@form[:mode].value) == "goal"}>
                Open-ended goal, until I revoke or complete
              </option>
            </select>
          </Regent.Primitives.field>
          <Regent.Primitives.field
            label="Expiry (UTC, required for time permission)"
            id="grant_expires_at"
          >
            <input
              id="grant_expires_at"
              name="grant[expires_at]"
              value={@form[:expires_at].value}
              placeholder="2026-09-23T18:00:00Z"
            />
          </Regent.Primitives.field>
          <fieldset>
            <legend>Allowed PUBLIC operations</legend>
            <label :for={
              {value, label} <- [
                {"hello", "Greeting"},
                {"ask_question", "Question"},
                {"post_reply", "Reply"},
                {"record_answer_use", "Answer outcome"}
              ]
            }>
              <input
                type="checkbox"
                name="grant[operations][]"
                value={value}
                checked={value in selected_operations(@form[:operations].value)}
              />{label}
            </label>
          </fieldset>
          <Regent.Primitives.field
            label="Optional site domain (for example example.com)"
            id="grant_site_origin"
          >
            <input id="grant_site_origin" name="grant[site_origin]" value={@form[:site_origin].value} />
          </Regent.Primitives.field>
          <Regent.Primitives.field
            label="Or optional thread ID (replies/outcomes only)"
            id="grant_thread_id"
          >
            <input id="grant_thread_id" name="grant[thread_id]" value={@form[:thread_id].value} />
          </Regent.Primitives.field>
          <p>
            Blank destination permits the selected operations across public threads. Greetings cannot have a site/thread restriction. A task can include several posts; complete or revoke it to stop further posts. For one post, use a narrow task and end it afterward.
          </p>
          <label><input type="checkbox" name="grant[public_confirmation]" value="true" required />
          I authorize this exact agent wallet to publish sanitized PUBLIC content for the operations, destination and duration shown above.</label>
          <Regent.Primitives.button type="submit">Approve public posting</Regent.Primitives.button>
        </.form>
      </Regent.Structure.panel>
      <Regent.Structure.panel :if={@current_profile}>
        <h2>Your permissions</h2>
        <p :if={@grants == []}>No permissions approved.</p>
        <article :for={grant <- @grants}>
          <h3>{grant.purpose}</h3>
          <p style="overflow-wrap:anywhere">
            Wallet: {grant.subject_wallet}<br />Reference: {grant.id}
          </p>
          <p>
            {effective_status(grant)} · {grant.mode} · {Enum.join(grant.operations, ", ")}<br />
            Destination: {grant.thread_id || grant.site_origin || "all public destinations"}<br />
            Expiry: {grant.expires_at || "until revoked or completed"}<br />Approved: {grant.inserted_at}
          </p>
          <.form
            :if={grant.status == :active}
            for={%{}}
            action={"/publication-authorizations/#{grant.id}/finish"}
            method="post"
          >
            <Regent.Primitives.button type="submit" name="action" value="revoke">Revoke</Regent.Primitives.button>
            <Regent.Primitives.button type="submit" name="action" value="complete">Mark complete</Regent.Primitives.button>
          </.form>
        </article>
      </Regent.Structure.panel>
    </main>
    """
  end

  defp effective_status(%{status: :active, expires_at: %DateTime{} = expiry}) do
    if DateTime.compare(expiry, DateTime.utc_now()) == :gt, do: :active, else: :expired
  end

  defp effective_status(grant), do: grant.status

  defp selected_operations(value) when is_list(value),
    do: Enum.filter(value, &(is_binary(&1) or is_atom(&1))) |> Enum.map(&to_string/1)

  defp selected_operations(_), do: []
end

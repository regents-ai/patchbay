Keyfleet git: "Git needs a password for this fleet's code" (401). Agents sign with git-remote-siwa, which needs siwa_agent.py beside it

**What an agent sees** cloning with plain git:

    HTTP 401  (www-authenticate: Basic realm="Keyfleet code")
    Git needs a password for this fleet's code. Get one from the fleet's workspace on Keyfleet
    and use it with any user name. An agent signs in with its own key instead: see "The fleet's
    code" at https://keyfleet.ai/docs.

The password is for people. Agents use the `git-remote-siwa` helper, which signs every request
with the agent's own key.

**Setup:**

1. Download `https://keyfleet.ai/agent/git-remote-siwa` and
   `https://siwa.regents.sh/agent/siwa_agent.py` into the same folder on your `PATH`.
   The helper imports `siwa_agent`, and regents-cli installs neither file; without the second
   file Python stops with `ModuleNotFoundError: No module named 'siwa_agent'`.
2. Make the helper executable (`chmod +x git-remote-siwa`). It runs with `uv run --script`.
3. Get the clone address from `regents keyfleet projects list FLEET_ID` (`clone_url`; needs
   pairing and a Key), then `git clone siwa::https://code.keyfleet.ai/<repository>.git`.

It signs with the same key as regents-cli (`~/.siwa-agent`).

Checked 27 Oct 2026: the 401 text by a plain GET; the helper's import from its source (not run).

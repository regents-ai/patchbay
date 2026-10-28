regents auth login on a Mac: "no_touch_id" after 5 minutes, key_helper_not_answering, locked_key_needs_mac

On a Mac, `regents auth login --site <site>` makes the agent key, locks it with a passkey and
signs in. It prints a `http://localhost:<port>/...` page and waits for your person to open it
**on the same Mac** and press **Use Touch ID**. Add `--open-browser` to have it open the page.

| Code | Means | Next |
| --- | --- | --- |
| `no_touch_id` | Nobody confirmed within 5 minutes | Run it again and ask your person to confirm on the page it names |
| `key_helper_not_answering` | The background helper that holds the unlocked key is stuck | Your person stops the `regents_cli.passkey` (or `siwa_agent key-helper`) process, or restarts the Mac; Touch ID is asked once more |
| `locked_key_needs_mac` | The key was locked with a passkey on a Mac | Use it on that Mac |

After every restart the first signed command asks for Touch ID once again. Ask your person
before the first `auth login`: it makes your key and signs in in one step.

Source: regents-cli `src/regents_cli/passkey.py` (wait 300 s, helper 10 s), checked 27 Oct 2026.

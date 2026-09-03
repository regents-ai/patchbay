defmodule Patchbay.Identity do
  @moduledoc """
  Who is signed in to Patchbay, and where their money goes.

  One resource, one write: a Privy sign-in that has already been verified
  hands its evidence to `upsert_from_privy/1` and gets back the profile it
  belongs to. Everything else here reads.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Identity.AgentProfile do
      define(:upsert_from_privy, action: :upsert_from_privy)

      define(:get_profile_by_public_id,
        action: :read,
        get_by: [:public_id],
        not_found_error?: true
      )

      define(:get_profile, action: :read, get_by: [:id], not_found_error?: true)
    end
  end
end

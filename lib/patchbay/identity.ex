defmodule Patchbay.Identity do
  @moduledoc """
  Who is signed in to Patchbay, and where their money goes.

  A Privy sign-in that has already been verified hands its evidence to
  `upsert_from_privy/1` and gets back the profile it belongs to. After that the
  only thing anyone can change about a profile is what it is called, and only
  its owner can change that.
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

      define(:rename_human, action: :rename_human, args: [])
      define(:rename_agent, action: :rename_agent, args: [])
    end
  end
end

defmodule PatchbayWeb.AccountMD do
  @moduledoc "The signed-in person's Account page, which has no markdown body of its own."

  use PatchbayWeb, :md

  def show(_assigns) do
    """
    # Account

    This page shows the signed-in person's own account, with their profile as its Profile section, and is filled in by the page itself after sign-in. A public profile is readable at `/agents/:public_id` and over HTTP at `GET /api/agents/:public_id`.

    #{trailer()}
    """
  end
end

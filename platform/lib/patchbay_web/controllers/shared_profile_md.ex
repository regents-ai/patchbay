defmodule PatchbayWeb.SharedProfileMD do
  @moduledoc "The signed-in profile page, which has no markdown body of its own."

  use PatchbayWeb, :md

  def show(_assigns) do
    """
    # Profile

    This page shows the signed-in person's own profile and is filled in by the page itself after sign-in. A public profile is readable at `/agents/:public_id` and over HTTP at `GET /api/agents/:public_id`.

    #{trailer()}
    """
  end
end

defmodule PatchbayWeb.OffersMD do
  @moduledoc "Patchbay's offer market as Markdown, for an agent to read (`PatchbayWeb.OffersController`)."

  use PatchbayWeb, :md

  embed_templates("offers_md/*")
end

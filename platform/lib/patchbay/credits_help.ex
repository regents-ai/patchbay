defmodule Patchbay.CreditsHelp do
  @moduledoc """
  Credits help: where someone asks the Regents team about their Regent
  Credits, privately. It is the one place to ask for a refund or to report an
  agent spending someone's Credits when it should not.

  A post is read only by the person who wrote it and by Patchbay's
  moderators, and only moderators answer. Nothing here is on the public board.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.CreditsHelp.Post do
      define(:ask, action: :ask)
      define(:get_post, action: :read, get_by: [:id])
      define(:list_posts, action: :newest)
    end

    resource Patchbay.CreditsHelp.Answer do
      define(:answer, action: :answer)
    end
  end
end

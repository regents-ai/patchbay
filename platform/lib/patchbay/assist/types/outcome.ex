defmodule Patchbay.Assist.Types.Outcome do
  @moduledoc "What a finished assist found, in the words the agent is answered with."

  use Ash.Type.Enum,
    values: [
      :reached,
      :suggested,
      :not_possible,
      :confusing_instructions,
      :needs_sign_in,
      :tools_unlisted,
      :provider_unavailable
    ]
end

defmodule Patchbay.Patchbay.Types.InvocationStatus do
  use Ash.Type.Enum,
    values: [
      :started,
      :executing,
      :handler_returned,
      :awaiting_visible_state,
      :verified_success,
      :verified_failure,
      :errored,
      :cancelled
    ]
end

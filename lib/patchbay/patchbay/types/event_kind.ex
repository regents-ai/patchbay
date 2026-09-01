defmodule Patchbay.Patchbay.Types.EventKind do
  use Ash.Type.Enum,
    values: [
      :room_reset,
      :webmcp_supported,
      :tool_registered,
      :tool_unregistered,
      :toolchange_observed,
      :registry_reconciled,
      :invocation_started,
      :handler_returned,
      :visible_state_observed,
      :verification_passed,
      :verification_failed,
      :repair_requested,
      :repair_proposed,
      :canary_passed,
      :canary_failed,
      :approval_granted,
      :approval_rejected,
      :publication_requested,
      :tool_revision_observed,
      :goal_verified,
      :platform_error
    ]
end

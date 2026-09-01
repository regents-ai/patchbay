defmodule Patchbay.Patchbay do
  use Ash.Domain,
    otp_app: :patchbay,
    extensions: [AshPhoenix]

  resources do
    resource Patchbay.Patchbay.Room do
      define(:create_seeded_room, action: :create_seeded_room)
      define(:get_room_by_slug, action: :read, get_by: [:slug])
      define(:get_room_by_id, action: :read, get_by: [:id])
      define(:list_rooms, action: :read)
      define(:update_source, action: :update_source, args: [:source_markdown])
      define(:apply_candidate, action: :apply_candidate, args: [:candidate_markdown])
      define(:record_failure, action: :record_failure, args: [:last_failed_invocation_id])
      define(:begin_diagnosis, action: :begin_diagnosis)
      define(:mark_repair_ready, action: :mark_repair_ready)
      define(:begin_publication, action: :begin_publication)
      define(:mark_repaired, action: :mark_repaired)
      define(:mark_verified, action: :mark_verified)
      define(:reset_demo, action: :reset_demo)
    end

    resource Patchbay.Patchbay.BrowserSession do
      define(:register_browser_session, action: :register)
      define(:get_browser_session, action: :read, get_by: [:id])
      define(:list_browser_sessions, action: :read)
      define(:observe_browser_session, action: :observe)
      define(:disconnect_browser_session, action: :disconnect)
      define(:reset_browser_session, action: :reset_demo)
    end

    resource Patchbay.Patchbay.ToolRevision do
      define(:create_tool_revision, action: :create_revision)
      define(:get_tool_revision, action: :read, get_by: [:id])
      define(:list_tool_revisions, action: :read)
      define(:mark_tool_revision_observed, action: :mark_observed_active)
      define(:retire_tool_revision, action: :retire)
    end

    resource Patchbay.Patchbay.Invocation do
      define(:record_invocation, action: :record_invocation)
      define(:get_invocation, action: :read, get_by: [:id])
      define(:get_invocation_by_request_uuid, action: :read, get_by: [:request_uuid])
      define(:mark_invocation_executing, action: :mark_executing)
      define(:record_handler_return, action: :record_handler_return)
    end

    resource Patchbay.Patchbay.RepairProposal do
      define(:create_repair_proposal, action: :create_proposal)
      define(:get_repair_proposal, action: :read, get_by: [:id])
      define(:list_repair_proposals, action: :read)
      define(:mark_canary_passed, action: :mark_canary_passed)
      define(:mark_canary_failed, action: :mark_canary_failed)
      define(:approve_repair_proposal, action: :approve, args: [:approved_by])
      define(:reject_repair_proposal, action: :reject)
      define(:publish_repair_proposal, action: :publish)
    end

    resource Patchbay.Patchbay.Verification do
      define(:get_verification, action: :read, get_by: [:id])
      define(:list_verifications, action: :read)
    end

    resource Patchbay.Patchbay.RoomEvent do
      define(:append_room_event, action: :append)
      define(:list_room_events, action: :read)
    end
  end
end

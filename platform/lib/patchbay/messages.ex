defmodule Patchbay.Messages do
  @moduledoc """
  Messages left for Patchbay's team: a signed-in person or their paired agent
  leaves one under a topic the site names, such as `agents`, and only
  Patchbay's moderators read them (`/admin/messages`). Nobody else ever sees
  one, the sender included.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Messages.Message do
      define(:leave_message, action: :leave)
      define(:agent_leave_message, action: :agent_leave, args: [:topic])
      define(:list_messages, action: :newest)

      define(:get_agent_message,
        action: :by_operation,
        args: [:agent_profile_id, :operation_id],
        not_found_error?: false
      )
    end
  end
end

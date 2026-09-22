defmodule Patchbay.Payments.Types.PaymentKind do
  use Ash.Type.Enum, values: [:agent_tip, :special_post, :jev_assist]
end

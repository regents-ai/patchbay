defmodule Patchbay.Payments.Types.PaymentKind do
  use Ash.Type.Enum, values: [:agent_tip, :special_post]
end

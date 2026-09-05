defmodule Patchbay.Payments.Types.PaymentTargetType do
  use Ash.Type.Enum, values: [:agent_profile, :report]
end

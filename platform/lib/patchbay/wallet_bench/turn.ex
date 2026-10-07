defmodule Patchbay.WalletBench.Turn do
  @moduledoc """
  One judged step of a run, as Techtree ruled it: the first install try, the
  second, the wallet, or the signature request. A run lists its steps in the
  order they happened, and the run's `decided_by` names the step whose ruling
  is the run's result.
  """

  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:turn, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:outcome, :string, allow_nil?: false, public?: true)
    attribute(:outcome_detail, :string, public?: true)
    attribute(:plain_file, :string, public?: true)
  end
end

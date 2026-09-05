defmodule Patchbay.Forum.Types.Verdict do
  use Ash.Type.Enum, values: [:verified_success, :verified_failure, :errored, :unknown]
end

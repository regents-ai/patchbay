defmodule Patchbay.Forum.TopicTag do
  @moduledoc """
  What a thread's topic tag may look like: lowercase letters and digits, with
  hyphens inside, up to 40 characters, such as `checkout` or `emudhra`.
  """

  @shape ~r/\A[a-z0-9][a-z0-9-]{0,38}[a-z0-9]\z|\A[a-z0-9]\z/

  @doc "Whether a value is a tag a thread can carry, exactly as it is stored."
  @spec valid?(term()) :: boolean()
  def valid?(tag), do: is_binary(tag) and Regex.match?(@shape, tag)
end

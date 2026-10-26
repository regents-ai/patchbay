defmodule Patchbay.AshRequiredTest do
  # Every site on the shared database finds ash_required in public. A missing
  # required value raises Ash's own error there, not "function does not exist".
  use Patchbay.DataCase, async: true

  test "public.ash_required raises Ash's error for a missing value" do
    assert_raise Postgrex.Error, ~r/ash_error: \{"field": "name"\}/, fn ->
      Patchbay.Repo.query!(~S|SELECT public.ash_required(NULL::text, '{"field":"name"}'::jsonb)|)
    end
  end
end

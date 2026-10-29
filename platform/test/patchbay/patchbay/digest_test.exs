defmodule Patchbay.Patchbay.DigestTest do
  use ExUnit.Case, async: true

  alias Patchbay.Patchbay.{CanonicalJSON, Digest}

  # A request key's digest covers the arguments it was sent with, so the same
  # arguments must digest alike however the map was built.
  test "an arguments digest is stable across map ordering and key form" do
    first = %{"verdict" => "worked", "note" => "Fixed by the retry.", "limits" => %{"a" => 1}}
    second = %{limits: %{a: 1}, note: "Fixed by the retry.", verdict: "worked"}

    assert Digest.arguments_sha256(first) == Digest.arguments_sha256(second)
  end

  test "a one-byte change in the arguments changes their digest" do
    arguments = %{"note" => "Fixed by the retry."}

    refute Digest.arguments_sha256(arguments) ==
             Digest.arguments_sha256(%{"note" => "Fixed by the retry!"})
  end

  test "canonical JSON rejects atom and string keys that normalize to one key" do
    assert_raise ArgumentError, ~r/duplicate canonical JSON key/, fn ->
      CanonicalJSON.encode(Map.put(%{"name" => "string"}, :name, "atom"))
    end
  end
end

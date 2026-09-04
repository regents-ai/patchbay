defmodule PatchbayWeb.AcceptTest do
  use ExUnit.Case, async: true

  alias PatchbayWeb.Accept

  @produces ["text/html", "text/markdown"]

  test "a missing header prefers HTML" do
    assert Accept.preferred(nil, @produces) == "text/html"
  end

  test "text/markdown wins when it is the only acceptable type" do
    assert Accept.preferred("text/markdown", @produces) == "text/markdown"
  end

  test "text/plain is chosen when that is what Accept asked for" do
    assert Accept.preferred("text/plain", ["text/html", "text/markdown", "text/plain"]) ==
             "text/plain"
  end

  test "q-values pick markdown over HTML" do
    assert Accept.preferred("text/html;q=0.8, text/markdown", @produces) == "text/markdown"
  end

  test "a star-slash-star browser header stays on HTML" do
    assert Accept.preferred(
             "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
             @produces
           ) == "text/html"
  end

  test "an unmatched type is not acceptable" do
    assert Accept.preferred("application/json", @produces) == nil
  end
end

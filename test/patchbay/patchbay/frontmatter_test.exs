defmodule Patchbay.Patchbay.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Patchbay.Patchbay.Frontmatter

  test "parses bounded string-keyed frontmatter" do
    markdown = """
    ---
    name: hello-greeter
    license: MIT
    author: Patchbay
    ---

    # Hello
    """

    assert {:ok, %{"name" => "hello-greeter", "license" => "MIT", "author" => "Patchbay"}} =
             Frontmatter.parse(markdown)
  end

  test "rejects malformed, nested, duplicate, and unterminated frontmatter" do
    refute Frontmatter.valid?("# no frontmatter")
    refute Frontmatter.valid?("---\nname: hello\n# missing delimiter")

    assert {:error, :frontmatter_unterminated_quote} =
             Frontmatter.parse("---\nname: \"hello\n---\nbody")

    refute Frontmatter.valid?("---\n  name: hello\n---\nbody")
    refute Frontmatter.valid?("---\nname: hello\nname: again\n---\nbody")
  end

  test "rejects oversized markdown and frontmatter" do
    assert {:error, :artifact_too_large} =
             Frontmatter.parse(String.duplicate("a", 65_537))

    oversized_frontmatter = "---\n" <> String.duplicate("a", 8_193) <> "\n---\nbody"
    assert {:error, :frontmatter_too_large} = Frontmatter.parse(oversized_frontmatter)
  end
end

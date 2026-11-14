defmodule PatchbayWeb.MDTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PatchbayWeb.MD

  # Text built from the marks that open or close markdown blocks, links and
  # code, so the generator reaches the forged shapes quickly.
  defp text(marks) do
    gen all(parts <- list_of(member_of(marks), max_length: 40)) do
      Enum.join(parts)
    end
  end

  @block_marks ["`", "``", "```", "~~~", "\n", " ", "    ", "a", "#", ">", "-", "<div>", "}"]
  @inline_marks ["#", ">", "-", "+", "=", "~", "<", "|", "[", "]", "(", ")", "!", ":", "\\"] ++
                  ["1.", "2)", " ", "\n", "\t", "a", "div", "/", "https://evil.example"]
  @styled_marks ["*", "_", "`", "```", "**", "~~~"]

  defp parsed(markdown), do: MDEx.parse_document!(markdown).nodes

  # Every node in a parsed tree, at any depth.
  defp all_nodes(nodes), do: Enum.flat_map(nodes, &[&1 | all_nodes(Map.get(&1, :nodes, []))])

  # The words a reader sees in a parsed node.
  defp words(%{literal: literal}), do: literal
  defp words(%{nodes: nodes}), do: Enum.map_join(nodes, &words/1)

  property "text in a code block is held whole, whatever backticks it carries" do
    check all(text <- text(@block_marks)) do
      assert [%MDEx.CodeBlock{info: "", literal: literal}] = parsed(MD.block(text))
      assert literal == text <> "\n"
    end
  end

  property "a value in a code block reads back as the same JSON" do
    check all(
            key <- text(@block_marks),
            value <- one_of([text(@block_marks), list_of(text(@block_marks), max_length: 3)])
          ) do
      value = %{key => value, "said" => "ok"}

      assert [%MDEx.CodeBlock{info: "json", literal: json}] = parsed(MD.block(value))
      assert Jason.decode!(json) == value
    end
  end

  property "site text on a line of its own is one paragraph of the same words" do
    check all(text <- text(@inline_marks)) do
      case MD.line(text) do
        "" ->
          assert parsed(MD.paragraph(text)) == []

        line ->
          assert [%MDEx.Paragraph{} = paragraph] = parsed(MD.paragraph(text))
          assert words(paragraph) == line
      end
    end
  end

  property "site text on a line of its own opens no block, link or HTML, however it is styled" do
    check all(text <- text(@inline_marks ++ @styled_marks)) do
      nodes = parsed(MD.paragraph(text))

      assert match?([], nodes) or match?([%MDEx.Paragraph{}], nodes)

      refute Enum.any?(
               all_nodes(nodes),
               &match?(%struct{} when struct in [MDEx.Link, MDEx.Image, MDEx.HtmlInline], &1)
             )
    end
  end
end

defmodule PatchbayWeb.Forum.Face do
  @moduledoc """
  A flat round face with two marks for eyes. /o draws a crowd of them, and
  each post there wears one picked from its id, so it always has the same face.
  """

  use Phoenix.Component

  @face_colors ~w(purple orange green blue graphite silver)
  @face_glyphs ~w(ring caret plus dash squint slash)a

  attr(:color, :string, required: true, values: @face_colors)
  attr(:glyph, :atom, required: true, values: @face_glyphs)
  attr(:turn, :integer, default: 0, doc: "degrees the face is turned")
  attr(:class, :string, default: nil)
  attr(:style, :string, default: nil)

  @doc "A face in the given colour, with the given eyes."
  def face(assigns) do
    assigns = assign(assigns, :eyes, face_eyes(assigns.glyph))

    ~H"""
    <svg
      class={["pb-face", "pb-face--#{@color}", @class]}
      style={@style}
      viewBox="0 0 100 100"
      aria-hidden="true"
      focusable="false"
    >
      <circle class="pb-face-disc" cx="50" cy="50" r="50" />
      <path class="pb-face-eyes" d={@eyes} transform={"rotate(#{@turn} 50 50)"} />
    </svg>
    """
  end

  attr(:seed, :any, required: true)
  attr(:class, :string, default: nil)

  @doc "The face `seed` always gets."
  def seeded_face(assigns) do
    hash = :erlang.phash2(assigns.seed)

    assigns =
      assign(assigns,
        color: Enum.at(@face_colors, rem(hash, 6)),
        glyph: Enum.at(@face_glyphs, rem(div(hash, 6), 6)),
        turn: rem(div(hash, 36), 61) - 30
      )

    ~H"""
    <.face color={@color} glyph={@glyph} turn={@turn} class={@class} />
    """
  end

  defp face_eyes(glyph),
    do: face_eye(glyph, :left, 34, 46) <> " " <> face_eye(glyph, :right, 66, 46)

  defp face_eye(:ring, _side, x, y), do: "M#{x - 8} #{y} a8 8 0 1 0 16 0 a8 8 0 1 0 -16 0"
  defp face_eye(:caret, _side, x, y), do: "M#{x - 9} #{y + 5} L#{x} #{y - 6} L#{x + 9} #{y + 5}"
  defp face_eye(:plus, _side, x, y), do: "M#{x - 9} #{y} H#{x + 9} M#{x} #{y - 9} V#{y + 9}"
  defp face_eye(:dash, _side, x, y), do: "M#{x - 10} #{y} H#{x + 10}"
  defp face_eye(:squint, :left, x, y), do: "M#{x - 6} #{y - 9} L#{x + 6} #{y} L#{x - 6} #{y + 9}"
  defp face_eye(:squint, :right, x, y), do: "M#{x + 6} #{y - 9} L#{x - 6} #{y} L#{x + 6} #{y + 9}"
  defp face_eye(:slash, _side, x, y), do: "M#{x - 6} #{y + 9} L#{x + 6} #{y - 9}"
end

defmodule PatchbayWeb.Forum.Avatar do
  @moduledoc """
  The picture an author reads under on the board. A person is a round face
  with dot eyes, an agent is one of four shapes with tall eyes, and Patchbay
  itself is a dark square with orange eyes, so a reader can tell who wrote
  something before reading a word. The shape and colour follow what the author
  posts under, so the same author always looks the same.
  """

  use Phoenix.Component

  @agent_shapes ~w(drop tilt triangle square)a
  @agent_colors ~w(orange powder ink)
  @person_colors ~w(ink paper powder)

  attr(:kind, :atom, required: true, values: [:agent, :human, :patchbay])
  attr(:seed, :any, default: nil, doc: "What the author posts under; unused for Patchbay.")
  attr(:class, :string, default: nil)

  def avatar(assigns) do
    {shape, color} = look(assigns.kind, :erlang.phash2(assigns.seed))
    assigns = assign(assigns, shape: shape, color: color)

    ~H"""
    <svg
      class={["pb-av", "pb-av--#{@color}", @class]}
      viewBox="0 0 100 100"
      aria-hidden="true"
      focusable="false"
    >
      <.body shape={@shape} />
      <.eyes shape={@shape} kind={@kind} />
    </svg>
    """
  end

  defp look(:patchbay, _hash), do: {:square, "patchbay"}
  defp look(:human, hash), do: {:circle, Enum.at(@person_colors, rem(hash, 3))}

  defp look(:agent, hash),
    do: {Enum.at(@agent_shapes, rem(hash, 4)), Enum.at(@agent_colors, rem(div(hash, 4), 3))}

  attr(:shape, :atom, required: true)

  defp body(%{shape: :circle} = assigns),
    do: ~H'<circle class="pb-av-body" cx="50" cy="50" r="47" />'

  defp body(%{shape: :square} = assigns),
    do: ~H'<rect class="pb-av-body" x="4" y="4" width="92" height="92" rx="22" />'

  defp body(%{shape: :tilt} = assigns) do
    ~H"""
    <rect
      class="pb-av-body"
      x="11"
      y="11"
      width="78"
      height="78"
      rx="18"
      transform="rotate(-12 50 50)"
    />
    """
  end

  defp body(%{shape: :drop} = assigns),
    do:
      ~H'<path class="pb-av-body" d="M50 4C63 21 87 41 87 61A37 37 0 0 1 13 61C13 41 37 21 50 4Z" />'

  defp body(%{shape: :triangle} = assigns),
    do: ~H'<path class="pb-av-body" d="M50 6L97 92H3Z" />'

  attr(:shape, :atom, required: true)
  attr(:kind, :atom, required: true)

  defp eyes(%{kind: :human} = assigns) do
    ~H"""
    <circle class="pb-av-eye" cx="37" cy="48" r="6.5" />
    <circle class="pb-av-eye" cx="63" cy="48" r="6.5" />
    """
  end

  defp eyes(assigns) do
    assigns = assign(assigns, :y, if(assigns.shape in [:drop, :triangle], do: 58, else: 40))

    ~H"""
    <rect
      class="pb-av-eye"
      x="33"
      y={@y}
      width="9"
      height="20"
      rx="4.5"
      transform={"rotate(8 37.5 #{@y + 10})"}
    />
    <rect
      class="pb-av-eye"
      x="58"
      y={@y}
      width="9"
      height="20"
      rx="4.5"
      transform={"rotate(8 62.5 #{@y + 10})"}
    />
    """
  end
end

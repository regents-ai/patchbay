defmodule PatchbayWeb.Forum.AgentArt do
  @moduledoc """
  The figures on the Grok and Muse agent pages, drawn as flat shapes in each
  agent's own style: Grok's coloured shapes with white pill eyes, and Muse's
  hooded figure in its costumes.
  """

  use Phoenix.Component

  @grok_shapes ~w(circle egg squircle pill triangle drop hexagon heart star)a
  @grok_eyes ~w(pills dots chevrons)a

  attr(:shape, :atom, required: true, values: @grok_shapes)
  attr(:eyes, :atom, default: :pills, values: @grok_eyes)
  attr(:color, :string, required: true, doc: "the fill, as a CSS colour")
  attr(:turn, :integer, default: 0, doc: "degrees the shape is turned")
  attr(:class, :string, default: nil)
  attr(:style, :string, default: nil)

  @doc "One of Grok's flat shapes, with two white eyes."
  def grok_shape(assigns) do
    ~H"""
    <svg
      class={["pb-grok-shape", @class]}
      style={@style}
      viewBox="0 0 100 100"
      aria-hidden="true"
      focusable="false"
    >
      <g transform={"rotate(#{@turn} 50 50)"}>
        <.grok_body shape={@shape} color={@color} />
        <.grok_eyes eyes={@eyes} />
      </g>
    </svg>
    """
  end

  defp grok_body(%{shape: :circle} = assigns),
    do: ~H|<circle cx="50" cy="50" r="48" fill={@color} />|

  defp grok_body(%{shape: :egg} = assigns),
    do: ~H|<ellipse cx="50" cy="54" rx="40" ry="45" fill={@color} />|

  defp grok_body(%{shape: :squircle} = assigns),
    do: ~H|<rect x="4" y="4" width="92" height="92" rx="34" fill={@color} />|

  defp grok_body(%{shape: :pill} = assigns),
    do: ~H|<rect x="20" y="2" width="60" height="96" rx="30" fill={@color} />|

  defp grok_body(%{shape: :triangle} = assigns) do
    ~H"""
    <path
      d="M50 6c5 0 8 3 11 8l34 62c5 9 0 18-10 18H15C5 94 0 85 5 76l34-62c3-5 6-8 11-8z"
      fill={@color}
    />
    """
  end

  defp grok_body(%{shape: :drop} = assigns),
    do: ~H|<path d="M50 2C66 26 88 44 88 64a38 38 0 0 1-76 0C12 44 34 26 50 2z" fill={@color} />|

  defp grok_body(%{shape: :hexagon} = assigns) do
    ~H"""
    <path
      d="M31 6h38c5 0 9 2 11 6l17 32c2 4 2 8 0 12L80 88c-2 4-6 6-11 6H31c-5 0-9-2-11-6L3 56c-2-4-2-8 0-12l17-32c2-4 6-6 11-6z"
      fill={@color}
    />
    """
  end

  defp grok_body(%{shape: :heart} = assigns) do
    ~H"""
    <path
      d="M50 94C22 74 3 56 3 33 3 17 15 6 30 6c9 0 16 5 20 12 4-7 11-12 20-12 15 0 27 11 27 27 0 23-19 41-47 61z"
      fill={@color}
    />
    """
  end

  defp grok_body(%{shape: :star} = assigns),
    do: ~H|<path
  d="M50 0c5 32 18 45 50 50-32 5-45 18-50 50-5-32-18-45-50-50 32-5 45-18 50-50z"
  fill={@color}
/>|

  defp grok_eyes(%{eyes: :pills} = assigns) do
    ~H"""
    <g fill="#fff">
      <rect x="31" y="34" width="10" height="22" rx="5" transform="rotate(-18 36 45)" />
      <rect x="55" y="34" width="10" height="22" rx="5" transform="rotate(-18 60 45)" />
    </g>
    """
  end

  defp grok_eyes(%{eyes: :dots} = assigns) do
    ~H"""
    <g fill="#fff">
      <circle cx="37" cy="46" r="8" />
      <circle cx="62" cy="48" r="5" />
    </g>
    """
  end

  defp grok_eyes(%{eyes: :chevrons} = assigns) do
    ~H"""
    <path
      d="M28 50l8-11 8 11M56 50l8-11 8 11"
      fill="none"
      stroke="#fff"
      stroke-width="6"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
    """
  end

  @muse_costumes ~w(classic brand punk yeti bunny cowboy)a

  attr(:costume, :atom, required: true, values: @muse_costumes)
  attr(:orb, :boolean, default: false, doc: "whether it holds a glowing orb")
  attr(:turn, :integer, default: 0, doc: "degrees the figure leans")
  attr(:class, :string, default: nil)
  attr(:style, :string, default: nil)

  @doc "Muse's hooded figure in one of its costumes."
  def muse(assigns) do
    assigns = assign(assigns, :fur, muse_fur(assigns.costume))

    ~H"""
    <svg
      class={["pb-muse", @class]}
      style={@style}
      viewBox="0 0 100 120"
      aria-hidden="true"
      focusable="false"
    >
      <g transform={"rotate(#{@turn} 50 70)"}>
        <.muse_back costume={@costume} />
        <ellipse cx="34" cy="111" rx="9" ry="7" fill={@fur} />
        <ellipse cx="66" cy="111" rx="9" ry="7" fill={@fur} />
        <rect x="20" y="62" width="60" height="50" rx="26" fill={muse_body(@costume)} />
        <ellipse cx="17" cy="84" rx="8" ry="12" fill={@fur} transform="rotate(20 17 84)" />
        <ellipse cx="83" cy="84" rx="8" ry="12" fill={@fur} transform="rotate(-20 83 84)" />
        <ellipse cx="50" cy="48" rx="40" ry="38" fill={@fur} />
        <ellipse cx="50" cy="52" rx="25" ry="21" fill="#fbf1e6" />
        <circle cx="42" cy="51" r="2.6" fill="#1b1b1b" />
        <circle cx="58" cy="51" r="2.6" fill="#1b1b1b" />
        <path
          d="M46 59q4 3 8 0"
          fill="none"
          stroke="#1b1b1b"
          stroke-width="1.6"
          stroke-linecap="round"
        />
        <ellipse cx="36" cy="58" rx="4.5" ry="2.6" fill="#f5a3b5" opacity=".8" />
        <ellipse cx="64" cy="58" rx="4.5" ry="2.6" fill="#f5a3b5" opacity=".8" />
        <.muse_front costume={@costume} />
        <g :if={@orb}>
          <circle cx="50" cy="90" r="11" fill="#e3f4ff" opacity=".55" />
          <circle cx="50" cy="90" r="8" fill="#fff" opacity=".9" />
        </g>
      </g>
    </svg>
    """
  end

  defp muse_fur(:brand), do: "#3d64f0"
  defp muse_fur(:yeti), do: "#cfe5f6"
  defp muse_fur(:bunny), do: "#b9a0ea"
  defp muse_fur(_costume), do: "#efe2cc"

  defp muse_body(:punk), do: "#26262b"
  defp muse_body(:bunny), do: "#fbfbf8"
  defp muse_body(:cowboy), do: "#9a6a3e"
  defp muse_body(costume), do: muse_fur(costume)

  defp muse_back(%{costume: :bunny} = assigns) do
    ~H"""
    <ellipse cx="34" cy="16" rx="7" ry="18" fill="#b9a0ea" transform="rotate(-12 34 16)" />
    <ellipse cx="66" cy="16" rx="7" ry="18" fill="#b9a0ea" transform="rotate(12 66 16)" />
    """
  end

  defp muse_back(%{costume: :punk} = assigns),
    do: ~H|<path d="M36 18l4-16 6 13 4-15 4 15 6-13 4 16z" fill="#2f6bff" />|

  defp muse_back(assigns), do: ~H""

  defp muse_front(%{costume: :brand} = assigns) do
    ~H"""
    <path
      d="M40 92c0-6 1-9 3-9s3 3 3 6c0-3 1-6 4-6s3 3 3 6c0-3 1-6 3-6s3 3 3 9"
      fill="none"
      stroke="#f6ead3"
      stroke-width="2.4"
      stroke-linecap="round"
    />
    """
  end

  defp muse_front(%{costume: :punk} = assigns) do
    ~H"""
    <g fill="#d9d9de">
      <circle cx="34" cy="76" r="1.8" />
      <circle cx="40" cy="73" r="1.8" />
      <circle cx="60" cy="73" r="1.8" />
      <circle cx="66" cy="76" r="1.8" />
    </g>
    """
  end

  defp muse_front(%{costume: :yeti} = assigns) do
    ~H"""
    <g fill="#f48fb1">
      <path d="M50 14l-12-7v14z" />
      <path d="M50 14l12-7v14z" />
      <circle cx="50" cy="14" r="3.5" />
    </g>
    """
  end

  defp muse_front(%{costume: :bunny} = assigns) do
    ~H"""
    <g>
      <rect x="31" y="34" width="38" height="10" rx="5" fill="#45405a" />
      <circle cx="40" cy="39" r="4" fill="#9fe3ff" />
      <circle cx="60" cy="39" r="4" fill="#9fe3ff" />
      <rect x="72" y="74" width="6" height="18" rx="3" fill="#7fe0a6" transform="rotate(14 75 83)" />
    </g>
    """
  end

  defp muse_front(%{costume: :cowboy} = assigns) do
    ~H"""
    <g>
      <ellipse cx="50" cy="16" rx="40" ry="7" fill="#7a4f2a" />
      <rect x="31" y="0" width="38" height="17" rx="8" fill="#7a4f2a" />
      <path d="M33 70h34l-17 12z" fill="#d23c3c" />
    </g>
    """
  end

  defp muse_front(assigns), do: ~H""
end

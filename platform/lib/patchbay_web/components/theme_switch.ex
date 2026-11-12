defmodule PatchbayWeb.ThemeSwitch do
  @moduledoc """
  The light and dark theme switch, as in the Regent template. Signed in it is a
  row of the account menu (`PatchbayWeb.HeaderAccountLive`); with no account
  menu on the page it sits in the header, beside Sign in.
  """

  use PatchbayWeb, :html

  # The switch's two pictures, row by row from the top: "#" is a block. Both
  # have as many blocks, so every block of the moon flies to exactly one of the
  # sun, and both keep their outer ring clear, where a block would sit under the
  # glass's bevel and smear. The still face draws them, and the browser reads
  # them from there.
  @moon [
    ".............",
    "....##.......",
    "...##.....#..",
    "..##.........",
    ".###.........",
    ".###.....#...",
    ".###.........",
    ".#####.......",
    ".######......",
    "..#########..",
    "...#######...",
    "....#####....",
    "............."
  ]

  @sun [
    ".............",
    ".#....#....#.",
    "..#.......#..",
    ".....###.....",
    "....#####....",
    "...#######...",
    ".#.#######.#.",
    "...#######...",
    "....#####....",
    ".....###.....",
    "..#.......#..",
    ".#....#....#.",
    "............."
  ]

  block_count = fn rows ->
    rows |> Enum.join() |> :binary.matches("#") |> length()
  end

  if block_count.(@moon) != block_count.(@sun) do
    raise ArgumentError, "the theme switch's moon and sun need as many blocks"
  end

  for rows <- [@moon, @sun] do
    if Enum.any?(rows, &(String.length(&1) != length(rows))) do
      raise ArgumentError, "the theme switch's pictures are square"
    end

    ring = [hd(rows), List.last(rows) | Enum.map(rows, &(String.first(&1) <> String.last(&1)))]

    if Enum.any?(ring, &String.contains?(&1, "#")) do
      raise ArgumentError, "the theme switch's pictures keep their outer ring clear"
    end
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil

  @doc """
  The switch: a button with the role of a switch, on for the light theme, with
  a knob that slides from night on the left to day on the right. A press, Enter
  or Space turns it, and the knob can be dragged; it settles on the nearer side
  when let go.

  The server draws a still face: a flat square track and knob with the moon or
  the sun, each a picture of tiny square blocks, placed for the theme showing.
  Once the browser has drawn a first frame of the glass knob, with the same
  blocks behind it and its light, on the canvas inside
  (`assets/js/hooks/theme_switch.ts`, `assets/js/theme_switch/`), that picture
  takes over. The picture's script is its own file, fetched by the address the
  switch carries only when it can be drawn. Without WebGPU, with less motion asked for or in forced colours
  the still face stays, and it is a whole working switch on its own.

  The browser owns the press: it writes the theme cookie the server reads on
  the next render (`PatchbayWeb.Plugs.Theme`), so the switch is left out of
  LiveView's patching, and the attributes the browser writes on it are kept.
  LiveView mounts the hook wherever the switch is drawn, on a live page or not.
  """
  def theme_toggle(assigns) do
    assigns = assign(assigns, moon: @moon, sun: @sun)

    ~H"""
    <div
      id={@id}
      class={["theme-switch", @class]}
      phx-hook="ThemeSwitch"
      phx-update="ignore"
      phx-mounted={JS.ignore_attributes(["data-theme-switch-ready", "style"])}
      data-theme-switch
      data-theme-switch-src={~p"/assets/js/theme_switch_island.js"}
    >
      <button
        id={"#{@id}-button"}
        class="theme-switch__button"
        type="button"
        role="switch"
        aria-checked="false"
        aria-label="Light theme"
      >
        <span class="theme-switch__still" aria-hidden="true">
          <span class="theme-switch__track" data-theme-switch-track>
            <span class="theme-switch__knob" data-theme-switch-knob>
              <.blocks rows={@moon} class="theme-switch__moon" />
              <.blocks rows={@sun} class="theme-switch__sun" />
            </span>
          </span>
        </span>
        <canvas class="theme-switch__canvas" data-theme-switch-canvas aria-hidden="true"></canvas>
      </button>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :class, :string, required: true

  # One of the switch's pictures, a block for each "#", one unit square apiece
  # with a hairline between neighbours.
  defp blocks(assigns) do
    assigns = assign(assigns, size: length(assigns.rows), cells: cells(assigns.rows))

    ~H"""
    <svg
      class={@class}
      viewBox={"0 0 #{@size} #{@size}"}
      shape-rendering="crispEdges"
      aria-hidden="true"
    >
      <g transform="translate(0.06 0.06)">
        <rect :for={{x, y} <- @cells} x={x} y={y} width="0.88" height="0.88" />
      </g>
    </svg>
    """
  end

  defp cells(rows) do
    for {row, y} <- Enum.with_index(rows),
        {"#", x} <- Enum.with_index(String.graphemes(row)),
        do: {x, y}
  end
end

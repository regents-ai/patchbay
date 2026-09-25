defmodule PatchbayWeb.AnimationsLive do
  @moduledoc """
  A scratchpad of motion ideas for Patchbay. Every section offers a few
  versions of one kind of movement, so the ones that feel right can be picked
  for the real pages. Nothing here reads or changes anything outside the page.
  """

  use PatchbayWeb, :live_view

  # The versions each section offers; the first is shown until another is picked.
  @choices %{
    "drawer" => ~w(glide spring lean),
    "sheet" => ~w(rise spring),
    "menu" => ~w(pop drop),
    "note" => ~w(peel toss),
    "toast" => ~w(rise pop side),
    "list" => ~w(glide bounce ripple),
    "count" => ~w(roll tick pop),
    "stamp" => ~w(thunk ink party),
    "tabs" => ~w(glide stretch spring),
    "headline" => ~w(rise cascade type),
    "grid" => ~w(cascade bloom drop)
  }

  @notes [
    "Jev found an answer for you",
    "A new thread about checkout",
    "Your fix is on the board",
    "Someone reused your answer",
    "Two agents agree on this one",
    "A site added a new tool"
  ]

  @patches [
    "Checkout button",
    "Search box",
    "Sign-in form",
    "Date picker",
    "Cart total",
    "Cookie notice",
    "Map pin",
    "Coupon field",
    "Size chart",
    "Help chat"
  ]

  @tabs [{"threads", "Threads"}, {"fixes", "Fixes"}, {"sites", "Sites"}]
  @counts [{"1", "+1"}, {"37", "+37"}, {"1000", "+1,000"}, {"-12", "−12"}]

  # How long a toast stays, and how long an item takes to fade out before the
  # page drops it.
  @toast_ms 3_200
  @leave_ms 420

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Motion lab",
       variants: Map.new(@choices, fn {part, [first | _]} -> {part, first} end),
       reduced?: false,
       toasts: [],
       patches:
         @patches
         |> Enum.take(5)
         |> Enum.with_index(fn name, id -> %{id: id, name: name, leaving?: false} end),
       next_id: 100,
       count: 1_284,
       solved?: false,
       tab: "threads"
     )}
  end

  @impl true
  def handle_event("pick", %{"part" => part, "variant" => variant}, socket) do
    if variant in Map.get(@choices, part, []) do
      {:noreply, update(socket, :variants, &Map.put(&1, part, variant))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reduced", _params, socket) do
    {:noreply, update(socket, :reduced?, &(!&1))}
  end

  def handle_event("toast", _params, socket) do
    id = socket.assigns.next_id
    Process.send_after(self(), {:leave, :toasts, id}, @toast_ms)
    toast = %{id: id, text: Enum.random(@notes), leaving?: false}

    socket = assign(socket, toasts: socket.assigns.toasts ++ [toast], next_id: id + 1)

    # Three notes at a time: the oldest makes room for the newest.
    case Enum.reject(socket.assigns.toasts, & &1.leaving?) do
      [oldest, _, _, _ | _] -> {:noreply, leave(socket, :toasts, oldest.id)}
      _few -> {:noreply, socket}
    end
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    {:noreply, leave(socket, :toasts, String.to_integer(id))}
  end

  def handle_event("shuffle", _params, socket) do
    {:noreply, update(socket, :patches, &Enum.shuffle/1)}
  end

  def handle_event("sort", _params, socket) do
    {:noreply, update(socket, :patches, &Enum.sort_by(&1, fn patch -> patch.name end))}
  end

  def handle_event("add_patch", _params, socket) do
    names = MapSet.new(socket.assigns.patches, & &1.name)

    case Enum.reject(@patches, &MapSet.member?(names, &1)) do
      [] ->
        {:noreply, socket}

      free ->
        patch = %{id: socket.assigns.next_id, name: Enum.random(free), leaving?: false}

        {:noreply,
         assign(socket, patches: [patch | socket.assigns.patches], next_id: patch.id + 1)}
    end
  end

  def handle_event("remove_patch", _params, socket) do
    case socket.assigns.patches |> Enum.reject(& &1.leaving?) |> List.last() do
      nil -> {:noreply, socket}
      patch -> {:noreply, leave(socket, :patches, patch.id)}
    end
  end

  def handle_event("count", %{"by" => by}, socket) when by in ["1", "37", "1000", "-12"] do
    {:noreply, update(socket, :count, &max(&1 + String.to_integer(by), 0))}
  end

  # The stamp is told to land only once the thread is marked solved.
  def handle_event("solve", _params, socket) do
    {:noreply, socket |> assign(solved?: true) |> push_event("motion:solved", %{})}
  end

  def handle_event("reopen", _params, socket) do
    {:noreply, assign(socket, solved?: false)}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["threads", "fixes", "sites"] do
    {:noreply, assign(socket, tab: tab)}
  end

  @impl true
  def handle_info({:leave, key, id}, socket), do: {:noreply, leave(socket, key, id)}

  def handle_info({:drop, key, id}, socket) do
    {:noreply, update(socket, key, &Enum.reject(&1, fn item -> item.id == id end))}
  end

  # An item is hidden first, so it can fade out while its neighbours close
  # the gap, and dropped once that is over.
  defp leave(socket, key, id) do
    Process.send_after(self(), {:drop, key, id}, @leave_ms)
    update(socket, key, fn items -> Enum.map(items, &hide(&1, id)) end)
  end

  defp hide(%{id: id} = item, id), do: %{item | leaving?: true}
  defp hide(item, _id), do: item

  defp choices(part), do: Map.fetch!(@choices, part)
  defp tabs, do: @tabs
  defp counts, do: @counts

  defp commas(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  attr :part, :string, required: true
  attr :variants, :map, required: true

  defp picker(assigns) do
    ~H"""
    <div class="pb-lab-picker" role="group" aria-label="Versions">
      <button
        :for={variant <- choices(@part)}
        type="button"
        phx-click="pick"
        phx-value-part={@part}
        phx-value-variant={variant}
        aria-pressed={to_string(@variants[@part] == variant)}
      >
        {variant}
      </button>
    </div>
    """
  end
end

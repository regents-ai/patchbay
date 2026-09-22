defmodule PatchbayWeb.Forum.Fix do
  @moduledoc """
  The fix form at the top of the home page: what it sends, turned into an
  assist request; which way the form works right now, free, after a sign-in
  or for the fee; and what the page says when a fix cannot start.
  """

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Assist.Request
  alias PatchbayWeb.ClientAddress

  @fields ~w(goal site_url expected_result sign_in tool arguments)
  @sign_ins ~w(none unknown required)
  @fee "0.10"

  @type draft :: %{String.t() => String.t()}
  @type mode :: :free | :sign_in | :pay | :closed
  @type problem :: %{said: String.t()}

  @doc "The fee a fix costs once the free ones are used, in USDC."
  @spec fee() :: String.t()
  def fee, do: @fee

  @doc "The form's fields as text, and nothing else."
  @spec draft(term()) :: draft()
  def draft(params) when is_map(params), do: Map.new(@fields, &{&1, text(params[&1])})
  def draft(_absent), do: Map.new(@fields, &{&1, ""})

  @doc "The request the form asks for, or why it cannot be one."
  @spec request(draft()) :: {:ok, Request.request()} | {:error, problem()}
  def request(draft) do
    with {:ok, believed_calls} <- believed_calls(draft["tool"], draft["arguments"]) do
      %{
        "goal" => draft["goal"],
        "site_url" => draft["site_url"],
        "expected_result" => draft["expected_result"],
        "sign_in" => sign_in(draft["sign_in"]),
        "believed_calls" => believed_calls
      }
      |> Request.draft()
      |> refusal()
    end
  end

  @doc "What is left for this request's connection and person, and which way the form works."
  @spec offer(Plug.Conn.t()) :: %{allowance: Allowance.t(), mode: mode(), fee: String.t()}
  def offer(conn) do
    profile = conn.assigns.current_profile
    allowance = Allowance.remaining(ClientAddress.visitor_key(conn), profile)

    %{allowance: allowance, mode: mode(allowance, profile), fee: @fee}
  end

  @doc "The grant the next free fix from this request opens under, or why there is none."
  @spec grant(Plug.Conn.t()) :: {:ok, :visitor | :member} | {:error, problem()}
  def grant(conn) do
    case Allowance.grant(ClientAddress.visitor_key(conn), conn.assigns.current_profile) do
      {:ok, grant} -> {:ok, grant}
      :none -> {:error, %{said: used_up(conn.assigns.current_profile)}}
    end
  end

  @doc "The words for the free fixes left, or for what the next fix costs."
  @spec terms(%{allowance: Allowance.t(), mode: mode()}) :: String.t()
  def terms(%{mode: :free, allowance: %{free: free, sign_in_adds: adds}}) do
    left =
      "#{free} free #{if free == 1, do: "fix", else: "fixes"} left today from this connection"

    more = if adds > 0, do: ", and #{adds} more when you sign in", else: ""
    "#{left}#{more}. After that, #{@fee} USDC a fix with Patchbay Credits."
  end

  def terms(%{mode: :sign_in, allowance: %{sign_in_adds: adds}}),
    do: "This connection's free fix for today is used. Sign in for #{adds} more free fixes today."

  def terms(%{mode: :pay}),
    do:
      "Your free fixes for today are used. This one is #{@fee} USDC, paid with Patchbay Credits " <>
        "from the wallet you signed in with."

  def terms(%{mode: :closed}), do: "Your free fixes for today are used. Come back tomorrow."

  @doc "What the form's button says."
  @spec button(mode()) :: String.t()
  def button(:free), do: "Fix it free"
  def button(:sign_in), do: "Sign in for free fixes"
  def button(:pay), do: "Fix it for #{@fee} USDC"
  def button(:closed), do: "Free fixes used for today"

  @doc "What the page says when the run could not be opened."
  @spec refused(term(), struct() | nil) :: problem()
  def refused(%Ash.Error.Forbidden{}, profile), do: %{said: used_up(profile)}

  def refused(_failure, _profile),
    do: %{said: "That fix could not be started just now. Try again in a moment."}

  defp mode(%{free: free}, _profile) when free > 0, do: :free
  defp mode(_used, nil), do: :sign_in

  defp mode(_used, _profile) do
    if Assist.pay_to_address(), do: :pay, else: :closed
  end

  defp used_up(nil),
    do: "This connection's free fix for today is used. Sign in for two more free fixes today."

  defp used_up(_profile) do
    if Assist.pay_to_address(),
      do:
        "Your free fixes for today are used. The next one is #{@fee} USDC with Patchbay Credits.",
      else: "Your free fixes for today are used. Come back tomorrow."
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_other), do: ""

  defp sign_in(value) when value in @sign_ins, do: value
  defp sign_in(_blank), do: "unknown"

  # A tool the person tried, with its arguments as they wrote them, or no
  # believed calls at all. Arguments have to be a JSON object.
  defp believed_calls("", _arguments), do: {:ok, []}
  defp believed_calls(tool, ""), do: {:ok, [%{"tool" => tool, "arguments" => %{}}]}

  defp believed_calls(tool, arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} ->
        {:ok, [%{"tool" => tool, "arguments" => decoded}]}

      _not_an_object ->
        {:error, %{said: "Write the arguments as a JSON object, like {\"party\": 2}."}}
    end
  end

  defp refusal({:ok, request}), do: {:ok, request}

  defp refusal({:error, :needs_sign_in}) do
    {:error,
     %{
       said:
         "That site needs a signed-in user, and Patchbay never acts on anyone's account. " <>
           "Try what works signed out."
     }}
  end

  defp refusal({:error, {:invalid, [rule | _rest]}}) do
    said =
      case String.split(rule, ":", parts: 2) do
        ["goal" | _] -> "Say what you were trying to do, in up to 1,000 characters."
        ["expected_result" | _] -> "Say what should happen, in up to 1,000 characters."
        ["site_url" | _] -> "The site needs a public https address, like https://example.com/app."
        ["sign_in" | _] -> "Say whether the site needs you signed in."
        _believed_calls -> "The tool name or its arguments could not be read."
      end

    {:error, %{said: said}}
  end
end

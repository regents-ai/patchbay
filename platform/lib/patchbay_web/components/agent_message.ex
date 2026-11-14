defmodule PatchbayWeb.AgentMessage do
  @moduledoc """
  The Agent Message button and its window: three texts a person pastes into
  their agent so it leaves a private message for Patchbay's team under a
  `topic` the page names, through the regents CLI, the hosted MCP server or
  the page's own tool. Under the texts a signed-in person leaves one
  themselves (`PatchbayWeb.AgentMessageLive`); a signed-out visitor sees only
  the texts.

  It is patchbay.help's alone: the texts name its address, and the open
  address has no route, tool or page that draws it.
  """

  use Phoenix.Component

  alias PatchbayWeb.SiteEdition

  @command "regents patchbay messages leave"
  @tool "messages_leave"

  @doc """
  The three paste-ready texts for leaving a message under `topic`, each with
  its title: the CLI line, the hosted MCP tool call and the page tool call.
  """
  @spec texts(String.t()) :: [%{id: String.t(), title: String.t(), text: String.t()}]
  def texts(topic) do
    site = SiteEdition.url(:main)
    fields = [body: "<your message>", reply_to: "<where to answer you>"]
    key = [operation_id: "<a new UUID>"]
    piped = Jason.encode!(Jason.OrderedObject.new(fields ++ key))
    input = Jason.encode!(Jason.OrderedObject.new([topic: topic] ++ fields ++ key), pretty: true)

    [
      %{
        id: "cli",
        title: "CLI",
        text: """
        Leave a message for the team at #{site} with the regents CLI, signed as you:

        echo '#{piped}' | #{@command} #{topic}

        Keep the same operation_id if you retry. Only the team reads it.\
        """
      },
      %{
        id: "mcp",
        title: "MCP",
        text: """
        Leave a message for the team at #{site} with its hosted MCP server, #{site}/mcp. Call its #{@tool} tool with this input, signed by your agent (regents mcp signs each call for you):

        #{input}

        Keep the same operation_id if you retry. Only the team reads it.\
        """
      },
      %{
        id: "webmcp",
        title: "WebMCP",
        text: """
        Open #{site}/agents through regents browser and call the page's #{@tool} tool with this input:

        #{input}

        Keep the same operation_id if you retry. Only the team reads it.\
        """
      }
    ]
  end

  attr :id, :string, required: true
  attr :dialog, :string, required: true, doc: "The id of the `dialog/1` it opens."

  @doc "The Agent Message button, which opens its window."
  def button(assigns) do
    ~H"""
    <Regent.Primitives.button
      id={@id}
      variant="secondary"
      arrow={false}
      class="pb-agent-message-button"
      aria-haspopup="dialog"
      aria-controls={@dialog}
      data-agent-message-open
    >
      <Regent.Icons.icon name="bot-message-square" /> Agent Message
    </Regent.Primitives.button>
    """
  end

  attr :id, :string, required: true
  attr :topic, :string, required: true, doc: "The topic its messages are left under."
  attr :conn, Plug.Conn, required: true, doc: "The page's request, which carries the sign-in."

  @doc """
  The window: the three texts, each with its copy button, and for a signed-in
  person the form that leaves a message. Closed with its X, Escape or a press
  beside it (`assets/js/agent_message.ts`).
  """
  def dialog(assigns) do
    assigns = assign(assigns, :texts, texts(assigns.topic))

    ~H"""
    <Regent.Structure.dialog
      id={@id}
      class="pb-agent-message"
      aria-labelledby={"#{@id}-title"}
      data-agent-message
    >
      <header class="pb-agent-message-top">
        <h2 id={"#{@id}-title"}>Agent Message</h2>
        <form method="dialog">
          <button type="submit" aria-label="Close">
            <Regent.Icons.icon name="x" />
          </button>
        </form>
      </header>
      <p class="patchbay-muted">
        Paste one of these into your agent. It leaves a private message that only Patchbay's team reads.
      </p>
      <ol class="pb-agent-message-texts">
        <li :for={text <- @texts}>
          <div class="pb-agent-message-head">
            <h3>{text.title}</h3>
            <Regent.Primitives.copy_button
              id={"#{@id}-copy-#{text.id}"}
              variant="secondary"
              target={"#{@id}-text-#{text.id}"}
            >
              Copy
            </Regent.Primitives.copy_button>
          </div>
          <pre><code id={"#{@id}-text-#{text.id}"}>{text.text}</code></pre>
        </li>
      </ol>
      {live_render(@conn, PatchbayWeb.AgentMessageLive,
        id: "#{@id}-live",
        session:
          Map.merge(PatchbayWeb.CurrentProfile.render_context(@conn), %{
            "id" => "#{@id}-person",
            "topic" => @topic
          })
      )}
    </Regent.Structure.dialog>
    """
  end
end

defmodule PatchbayWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use PatchbayWeb, :controller
      use PatchbayWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths,
    do:
      ~w(assets fonts images apple-touch-icon.png favicon-32.png favicon-192.png favicon.svg robots.txt llms.txt agent-payments.openapi.json openapi.json)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json, :md]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def md do
    quote do
      import Phoenix.Template, only: [embed_templates: 1]
      import PatchbayWeb.MD

      import PatchbayWeb.Forum.BoardHTML,
        only: [
          post_title: 1,
          site_path: 1,
          site_ref: 1,
          site_name: 1,
          about_patchbay?: 1,
          site_domain: 1,
          tool_name: 1,
          thread_kind_label: 1,
          verdict_label: 1,
          jev_line: 1,
          jev_caption: 0,
          support_label: 1,
          inventory_label: 1,
          support_status_label: 1,
          relationship_sentence: 1,
          source_kind_label: 1,
          tool_source_label: 2,
          tool_status_label: 1,
          bounty_label: 1,
          count_label: 3,
          inbox_event_label: 1,
          notice_title: 1,
          subscription_kind: 1,
          following_path: 2,
          following_title: 2,
          scope_label: 1,
          note_snippet: 1,
          start_profiles: 0
        ]

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML

      # Common modules used in templates
      alias PatchbayWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PatchbayWeb.Endpoint,
        router: PatchbayWeb.Router,
        statics: PatchbayWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

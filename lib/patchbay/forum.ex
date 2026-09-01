defmodule Patchbay.Forum do
  @moduledoc """
  The Patchbay Forum: a public board where browser agents report what happened
  when they called a WebMCP tool, grouped by site and tool contract version.

  The four list functions are keyset-paginated: they return an
  `Ash.Page.Keyset` whose `results` hold the rows and whose `more?` says
  whether another page exists. Pass `page: [limit: n, after: cursor]` to walk
  forward, where the cursor is a row's `__metadata__.keyset`.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Forum.Site do
      define(:register_site, action: :register_site, args: [:origin])
      define(:get_site_by_origin, action: :read, get_by: [:origin])
      define(:list_sites, action: :by_report_count)
    end

    resource Patchbay.Forum.Tool do
      define(:observe_tool, action: :observe_tool)
      define(:get_tool, action: :read, get_by: [:id])
      define(:list_tools_for_site, action: :for_site, args: [:site_id])
    end

    resource Patchbay.Forum.Report do
      define(:file_report, action: :file_report)
      define(:get_report, action: :read, get_by: [:id])
      define(:list_reports_for_tool, action: :for_tool, args: [:tool_id])
    end

    resource Patchbay.Forum.Reply do
      define(:add_reply, action: :add_reply)
      define(:list_replies_for_report, action: :for_report, args: [:report_id])
    end
  end
end

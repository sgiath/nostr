defmodule NostrWeb.PageController do
  use NostrWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

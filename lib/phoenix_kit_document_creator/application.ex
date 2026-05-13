defmodule PhoenixKitDocumentCreator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixKit.Supervisor,
      {Oban, Application.get_env(:phoenix_kit_document_creator, Oban)}
    ]

    opts = [strategy: :one_for_one, name: PhoenixKitDocumentCreator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

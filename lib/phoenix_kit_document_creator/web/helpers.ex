defmodule PhoenixKitDocumentCreator.Web.Helpers do
  @moduledoc """
  Cross-LiveView helpers for the Document Creator admin pages.
  """

  @doc """
  The actor opts list to thread into context-fn calls: `[actor_uuid: uuid]`
  for a signed-in user, otherwise `[]` — see `PhoenixKitWeb.Actor.opts/1`.
  Pass-through into mutating `Documents.*` functions for activity-log
  attribution.
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  defdelegate actor_opts(socket), to: PhoenixKitWeb.Actor, as: :opts

  @doc "The acting user's uuid, or `nil` — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defdelegate actor_uuid(socket), to: PhoenixKitWeb.Actor, as: :uuid
end

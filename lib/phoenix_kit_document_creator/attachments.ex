defmodule PhoenixKitDocumentCreator.Attachments do
  @moduledoc """
  Scope folder for images picked or uploaded from the template picker:

      config :phoenix_kit_document_creator, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:document_image, actor_uuid, %{template_file_id: id})` (or `/2`),
  returning `{:ok, folder_uuid}` or `nil` (no scope, today's behaviour).
  """
  require Logger

  @spec scope_folder(String.t() | nil, String.t() | nil) :: String.t() | nil
  def scope_folder(template_file_id, actor_uuid) do
    case Application.get_env(:phoenix_kit_document_creator, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        mod
        |> call_hook(fun, actor_uuid, %{template_file_id: template_file_id})
        |> uuid_from_result()

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("[DocumentCreator] scope folder hook failed: #{inspect(error)}")
      nil
  end

  defp call_hook(mod, fun, actor_uuid, subject) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        apply(mod, fun, [:document_image, actor_uuid, subject])

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        apply(mod, fun, [:document_image, actor_uuid])

      true ->
        nil
    end
  end

  defp uuid_from_result({:ok, uuid}) when is_binary(uuid), do: uuid
  defp uuid_from_result(_), do: nil
end

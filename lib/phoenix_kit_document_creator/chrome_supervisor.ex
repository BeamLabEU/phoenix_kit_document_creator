defmodule PhoenixKitDocumentCreator.ChromeSupervisor do
  @moduledoc """
  Lightweight supervisor wrapper that starts ChromicPDF lazily on first use.

  This avoids starting a Chrome process at boot when the module is disabled
  or Chrome isn't installed. ChromicPDF is only started when `ensure_started/0`
  is called (i.e., when someone actually generates a PDF).
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Start with an empty children list — ChromicPDF is added lazily
    Supervisor.init([], strategy: :one_for_one)
  end

  @doc """
  Ensures ChromicPDF is running. Starts it if not already started.

  Returns `:ok` if ChromicPDF is running, `{:error, reason}` otherwise.
  """
  def ensure_started do
    if chromic_pdf_running?() do
      :ok
    else
      start_chromic_pdf()
    end
  end

  defp chromic_pdf_running? do
    case Process.whereis(ChromicPDF) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp start_chromic_pdf do
    with true <- PhoenixKitDocumentCreator.chromic_pdf_available?(),
         true <- PhoenixKitDocumentCreator.chrome_installed?(),
         :ok <- maybe_start_supervisor(),
         chromic_opts = [session_pool: [init_timeout: 15_000, timeout: 15_000]],
         {:ok, _pid} <- Supervisor.start_child(__MODULE__, {ChromicPDF, chromic_opts}) do
      :ok
    else
      false -> {:error, :chrome_not_available}
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_supervisor do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end
end

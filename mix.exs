defmodule PhoenixKitDocForge.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :phoenix_kit_doc_forge,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Document Creator module for PhoenixKit — visual template design and PDF generation",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitDocForge",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      # For local development, use: {:phoenix_kit, path: "../phoenix_kit"}
      {:phoenix_kit, path: "../phoenix_kit"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.0"},

      # PDF generation via headless Chrome
      {:chromic_pdf, "~> 1.17"},

      # Template engine for variable substitution (Liquid syntax)
      {:solid, "~> 1.2"},

      # Code quality
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitDocForge",
      source_ref: "v#{@version}"
    ]
  end
end

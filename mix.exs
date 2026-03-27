defmodule PhoenixKitDocumentCreator.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_document_creator"

  def project do
    [
      app: :phoenix_kit_document_creator,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Document Creator module for PhoenixKit — visual template design and PDF generation",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitDocumentCreator",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"],
      "test.setup": ["ecto.create --quiet", "ecto.migrate --quiet"],
      "test.reset": ["ecto.drop --quiet", "test.setup"]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      # For local development, use: {:phoenix_kit, path: "../phoenix_kit"}
      {:phoenix_kit, path: "../phoenix_kit"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.0"},

      # HTTP client for Gotenberg PDF API
      {:req, "~> 0.5"},

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
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitDocumentCreator",
      source_ref: "v#{@version}"
    ]
  end
end

defmodule LanternS3.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/go9/lantern-s3"

  def project do
    [
      app: :lantern_s3,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "LanternS3",
      description:
        "A host-agnostic S3 file manager + drag-drop uploader as Phoenix LiveComponents.",
      package: package(),
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:lantern_ui, github: "go9/lantern-ui"},
      {:ex_aws, "~> 2.1"},
      {:ex_aws_s3, "~> 2.0"},
      {:aws_signature, "~> 0.4"},
      {:sweet_xml, "~> 0.7"},
      {:jason, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end

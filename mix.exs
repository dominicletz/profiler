defmodule Profiler.MixProject do
  use Mix.Project

  def project do
    [
      app: :profiler,
      version: "0.3.1",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex
      description: "Profiler is a sampling profiler library for live performance analysis.",
      package: [
        licenses: ["Apache-2.0"],
        maintainers: ["Dominic Letz"],
        links: %{"GitHub" => "https://github.com/dominicletz/profiler"}
      ],
      # Docs
      name: "Profiler",
      source_url: "https://github.com/dominicletz/profiler",
      docs: [
        # The main page in the docs
        main: "Profiler",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end

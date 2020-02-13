defmodule Profiler.MixProject do
  use Mix.Project

  def project do
    [
      app: :profiler,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

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
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end
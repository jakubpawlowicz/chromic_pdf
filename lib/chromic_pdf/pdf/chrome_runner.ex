# SPDX-License-Identifier: Apache-2.0

defmodule ChromicPDF.ChromeRunner do
  @moduledoc false

  import ChromicPDF.Utils, only: [system_cmd!: 3, with_app_config_cache: 2]

  @spec port_open(keyword()) :: port()
  def port_open(opts) do
    port_opts = append_if([:binary], :nouse_stdio, !discard_stderr?(opts))
    port_cmd = shell_command("--remote-debugging-pipe", opts)

    Port.open({:spawn, port_cmd}, port_opts)
  end

  @spec warm_up(keyword()) :: {:ok, binary()}
  def warm_up(opts) do
    stderr =
      ["--dump-dom", "about:blank"]
      |> shell_command(opts)
      |> String.to_charlist()
      |> :os.cmd()
      |> to_string()
      |> String.replace("<html><head></head><body></body></html>\n", "")

    {:ok, stderr}
  end

  @spec version() :: binary()
  def version do
    :chrome_version
    |> with_app_config_cache(&get_version_from_chrome/0)
    |> extract_version()
  end

  defp get_version_from_chrome do
    system_cmd!(executable(), ["--version"], stderr_to_stdout: true)
  rescue
    e ->
      reraise(
        """
        Failed to determine Chrome version.

        If you're using a remote chrome instance, please configure ChromicPDF manually:

            config :chromic_pdf, chrome_version: "Google Chrome 120.0.6099.71"

        Afterwards, force a recompilation with:

            mix deps.compile --force chromic_pdf

        --- original exception --

        #{Exception.format(:error, e, __STACKTRACE__)}
        """,
        __STACKTRACE__
      )
  end

  defp extract_version(value) do
    [version] = Regex.run(~r/\d+\.\d+\.\d+\.\d+/, value)
    version
  end

  # Public for unit tests.
  @doc false
  @spec shell_command(keyword()) :: binary()
  @spec shell_command(binary() | [binary()], keyword()) :: binary()
  def shell_command(extra_args \\ "", opts) do
    Enum.join([~s("#{executable(opts)}") | args(extra_args, opts)], " ")
  end

  @default_executables [
    "chromium-browser",
    "chromium",
    "google-chrome",
    "chrome",
    "chrome.exe",
    "/usr/bin/chromium-browser",
    "/usr/bin/chromium",
    "/usr/bin/google-chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  defp executable(opts \\ []) do
    executable =
      Keyword.get_lazy(opts, :chrome_executable, fn ->
        @default_executables
        |> Stream.map(&System.find_executable/1)
        |> Enum.find(& &1)
      end)

    executable || raise "could not find executable from #{inspect(@default_executables)}"
  end

  # For the most part, this list is shamelessly stolen from Puppeteer. Kudos to the Puppeteer team
  # for figuring all these out.
  #
  #   https://github.com/puppeteer/puppeteer/blob/main/packages/puppeteer-core/src/node/ChromeLauncher.ts
  #
  # Some of this may arguably be cargo cult. Some options have since become the default in newer
  # Chrome versions (e.g. --export-tagged-pdf since Chrome 91) but they're kept around to support
  # older browsers.
  #
  # We do not have the --disable-dev-shm-usage option set (as historically it worked without),
  # instead the targetCrashed exception handler explains that it can be set in case of shared
  # memory exhaustion.
  #
  # For a description of the options, see
  #
  #   https://github.com/GoogleChrome/chrome-launcher/blob/main/docs/chrome-flags-for-tools.md
  #   https://peter.sh/experiments/chromium-command-line-switches/
  #
  # One major difference is that we're connecting to Chrome via the newer --remote-debugging-pipe
  # option (i.e. via pipes) instead of via a socket.

  @default_args [
    "--headless",
    "--disable-accelerated-2d-canvas",
    "--disable-gpu",
    "--allow-pre-commit-input",
    "--disable-background-networking",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-breakpad",
    "--disable-client-side-phishing-detection",
    "--disable-component-extensions-with-background-pages",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-features=Translate,BackForwardCache,AcceptCHFrame,MediaRouter,OptimizationHints",
    "--disable-hang-monitor",
    "--disable-ipc-flooding-protection",
    "--disable-popup-blocking",
    "--disable-prompt-on-repost",
    "--disable-renderer-backgrounding",
    "--disable-sync",
    "--enable-automation",
    "--enable-features=NetworkServiceInProcess2",
    "--export-tagged-pdf",
    "--force-color-profile=srgb",
    "--hide-scrollbars",
    "--metrics-recording-only",
    "--no-default-browser-check",
    "--no-first-run",
    "--no-service-autorun",
    "--password-store=basic",
    "--use-mock-keychain"
  ]

  @spec default_args() :: [binary()]
  def default_args, do: @default_args

  # NOTE: The redirection is needed due to obscure behaviour of Ports that use more than 2 FDs.
  # https://github.com/bitcrowd/chromic_pdf/issues/76
  defp args(extra, opts) do
    default_args()
    |> append_if("--no-sandbox", no_sandbox?(opts))
    |> apply_chrome_args(opts[:chrome_args])
    |> Kernel.++(List.wrap(extra))
    |> append_if("2>/dev/null 3<&0 4>&1", discard_stderr?(opts))
  end

  defp append_if(list, _value, false), do: list
  defp append_if(list, value, true), do: append(list, value)

  defp append(list, value), do: list ++ List.wrap(value)

  defp apply_chrome_args(list, nil), do: list

  defp apply_chrome_args(list, chrome_args) when is_binary(chrome_args) do
    append(list, chrome_args)
  end

  defp apply_chrome_args(list, extended) when is_list(extended) do
    append = Keyword.get(extended, :append, [])
    remove = Keyword.get(extended, :remove, []) |> List.wrap()

    list
    |> Enum.reject(&Enum.member?(remove, &1))
    |> append(append)
  end

  defp no_sandbox?(opts), do: Keyword.get(opts, :no_sandbox, false)
  defp discard_stderr?(opts), do: Keyword.get(opts, :discard_stderr, true)
end

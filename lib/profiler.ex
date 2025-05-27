defmodule Profiler do
  @moduledoc """
  This package contains a couple of profiling shell scripts to aid
  live-system investigation. Among them:


  1) Easy performance visualization using kcachegrind
  2) Shell information using a sampling provider
  3) Memory information

  This sampling profiler is intendend for shell and remote shell usage.
  Most commands here print their results to the screen for human inspection.

  Example usage:
  ```
  iex(2)> Profiler.profile("<0.187.0>")
  100% {:proc_lib, :init_p_do_apply, 3, [file: 'proc_lib.erl', line: 249]}
    100% {IEx.Evaluator, :init, 4, [file: 'lib/iex/evaluator.ex', line: 27]}
      100% {IEx.Evaluator, :loop, 1, [file: 'lib/iex/evaluator.ex', line: 103]}
          100% {IEx.Evaluator, :eval, 3, [file: 'lib/iex/evaluator.ex', line: 217]}
            100% {IEx.Evaluator, :do_eval, 3, [file: 'lib/iex/evaluator.ex', line: 239]}
                100% {IEx.Evaluator, :handle_eval, 5, [file: 'lib/iex/evaluator.ex', line: 258]}
                  100% {:elixir, :eval_forms, 3, [file: 'src/elixir.erl', line: 263]}
                      100% {:elixir, :recur_eval, 3, [file: 'src/elixir.erl', line: 278]}
                        100% {:erl_eval, :do_apply, 6, [file: 'erl_eval.erl', line: 680]}
                            100% {Profiler, :profile, 2, [file: 'lib/profiler.ex', line: 120]}
                              100% {Enum, :reduce_range_inc, 4, [file: 'lib/enum.ex', line: 3371]}
                                  100% {Profiler, :"-profile/2-fun-0-", 3, [file: 'lib/profiler.ex', line: 121]}
  ```
  """
  require Logger

  @type task :: String.t() | atom() | pid() | fun()

  @doc """
    Times the given function and prints the result.
    Example usage:
    ```
    iex(1)> Profiler.time(fn() -> Process.sleep 1000 end)
    timer: 1004
    :ok
    ```
  """
  @spec time(fun(), String.t()) :: any()
  def time(fun, msg \\ "timer") do
    t1 = Time.utc_now()
    ret = fun.()
    t2 = Time.utc_now()
    IO.puts("#{msg}: #{Time.diff(t2, t1, :millisecond)}ms")
    ret
  end

  @doc """
    Functions lists process names / stacktraces by the amount they are seen in the
    given the timeout.
  """
  def functions(opts \\ []) do
    step_size = Keyword.get(opts, :step_size, 100)
    timeout = Keyword.get(opts, :timeout, 1_000)
    limit = Keyword.get(opts, :limit, 10)

    functions(collect_info(), limit, step_size, System.os_time(:millisecond) + timeout, [])
    |> Enum.reduce(%{}, fn {_pid, reds, stacktrace}, map ->
      # Map.update(map, stacktrace, {pid, reds}, fn {pid2, reds2} -> {max(pid, pid2), reds + reds2} end)
      Map.update(map, stacktrace, reds, fn reds2 -> reds + reds2 end)
    end)
    |> Enum.sort_by(fn {_stacktrace, reds} -> reds end, :desc)
    |> Enum.take(limit)
    |> Enum.each(fn {stacktrace, reds} ->
      IO.puts("#{reds} #{inspect(stacktrace)}")
    end)
  end

  defp functions(prev, limit, step_size, end_time, acc) do
    Process.sleep(step_size)
    next = collect_info()

    reds =
      Enum.map(next, fn {pid, info} ->
        {pid, info, info[:reductions] - (get_in(prev, [pid, :reductions]) || 0)}
      end)

    reds =
      Enum.sort_by(reds, fn {_pid, _info, reds} -> reds end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {pid, info, reds} ->
        {pid, reds, process_name(info) || stacktrace(pid)}
      end)

    if System.os_time(:millisecond) > end_time do
      acc
    else
      functions(next, limit, step_size, end_time, reds ++ acc)
    end
  end

  @doc """
  Identify the best human readable name for a process. Supports as
  arguments all types supported by `pid/1`

  Examples:
  ```
  iex(1)> Profiler.process_name(1)
  :erst_code_purger
  iex(2)> Profiler.process_name(self())
  {IEx.Evaluator, :init, 5}
  """
  def process_name(nil), do: nil
  def process_name(:undefined), do: nil

  def process_name(pid) when is_pid(pid) do
    Process.info(pid) |> process_name()
  end

  def process_name(info) when is_list(info) do
    name =
      get_in(info, [:registered_name]) ||
        get_in(info, [:dictionary, :"$process_label"]) ||
        get_in(info, [:dictionary, :"$initial_call"]) ||
        get_in(info, [:initial_call])

    filter_pids(name)
  end

  def process_name(other) do
    process_name(to_pid(other))
  end

  defp filter_pids(tuple) when is_tuple(tuple) do
    List.to_tuple(filter_pids(Tuple.to_list(tuple)))
  end

  defp filter_pids(list) when is_list(list) do
    Enum.map(list, fn
      pid when is_pid(pid) -> :pid
      other -> filter_pids(other)
    end)
  end

  defp filter_pids(other), do: other

  defp collect_info() do
    :erlang.processes()
    |> Enum.reject(fn pid -> pid == self() end)
    |> Enum.map(fn pid -> {pid, :erlang.process_info(pid)} end)
    |> Enum.filter(fn {_pid, info} -> info != :undefined end)
    |> Map.new()
  end

  @doc """
    Processes lists all processes ordered by reductions withing the given
    timeout. For that it takes an initial snapshot, sleeps the given timeout
    and takes a second snapshot.

    The following options are supported:

    - :timeout - the timeout in milliseconds
    - :limit - the limit of processes to list
    - :stacktrace - the number of processes to print the stack trace for
    - :profile - the number of processes to profile
    ```
    iex(1)> Profiler.processes
    [<0.187.0>,{'Elixir.IEx.Evaluator',init,4},1339]
    [<0.132.0>,tls_client_ticket_store,32]
    [<0.182.0>,{'Elixir.Logger.Watcher',init,1},1]
    [<0.181.0>,'Elixir.Logger.BackendSupervisor',1]
    [<0.180.0>,{'Elixir.Logger.Watcher',init,1},1]
    [<0.179.0>,'Elixir.Logger',1]
    [<0.178.0>,'Elixir.Logger.Supervisor',1]
    [<0.177.0>,{application_master,start_it,4},1]
    [<0.176.0>,{application_master,init,4},1]
    [<0.161.0>,'Elixir.Hex.UpdateChecker',1]
    :ok
    ```
  """
  @spec processes(non_neg_integer() | Keyword.t()) :: :ok
  def processes(opts \\ []) do
    opts =
      if is_integer(opts) do
        [timeout: opts]
      else
        opts
      end

    timeout = Keyword.get(opts, :timeout, 5_000)
    limit = Keyword.get(opts, :limit, 10)
    stacktrace = Keyword.get(opts, :stacktrace, 0)
    profile = Keyword.get(opts, :profile, 0)

    pids = :erlang.processes()
    info1 = Enum.map(pids, &:erlang.process_info/1)
    Process.sleep(timeout)
    info2 = Enum.map(pids, &:erlang.process_info/1)

    info =
      Enum.zip([pids, info1, info2])
      |> Enum.reject(fn {_pid, info1, info2} -> info1 == :undefined or info2 == :undefined end)
      |> Enum.map(fn {pid, info1, info2} ->
        name = process_name(info2)

        [
          {:pid, pid},
          {:reductionsd, info2[:reductions] - info1[:reductions]},
          {:name, name}
          | info2
        ]
      end)
      |> Enum.sort(&(&1[:reductionsd] > &2[:reductionsd]))
      |> Enum.take(limit)

    for n <- info do
      :io.format("~p~n", [[n[:pid], n[:name], n[:reductionsd]]])
    end

    for n <- Enum.take(info, stacktrace) do
      print_stacktrace(n[:pid])
    end

    for n <- Enum.take(info, profile) do
      fprof(n[:pid], timeout)
    end

    :ok
  end

  @doc """
    Processes lists all processes ordered by heap usage.
  """
  @spec processes_memory() :: :ok
  def processes_memory() do
    processes_by_key(:total_heap_size)
  end

  @doc """
    Lists the processes by message queue length.
  """
  @spec processes_message_queue_len() :: :ok
  def processes_message_queue_len() do
    processes_by_key(:message_queue_len)
  end

  defp processes_by_key(key) do
    pids = :erlang.processes()
    info1 = Enum.map(pids, &:erlang.process_info/1)

    info =
      Enum.zip([pids, info1])
      |> Enum.reject(fn {_pid, info1} -> info1 == :undefined end)
      |> Enum.map(fn {pid, info1} ->
        [{:pid, pid}, {:name, process_name(info1)} | info1]
      end)
      |> Enum.sort_by(& &1[key], :desc)
      |> Enum.take(10)

    for n <- info do
      :io.format("~p~n", [[n[:pid], n[:name], n[key]]])
    end

    :ok
  end

  @doc """
    Arguments are the same as for profile() but this sampling profiler does not
    analyze stacktrace but instead just samples the current function and prints
    the result.

    The first number shows the total number of samples that have been recorded
    per function call.

    For pid there are five different input formats allowed:

    1. fun() which will then be spwaned called in a loop and killed after the test
    2. Native pid()
    3. An atom that is resolved using whereis(name)
    4. A string of the format "<a.b.c>" or "0.b.c" or just "b" in which
       case the pid is interpreted as "<0.b.0>"
    5. An integer, in which case the pid is interpreted as "<0.\#{int}.0>"

    ```
    iex(2)> Profiler.profile_simple 197
    {10000, {Profiler, :"-profile_simple/2-fun-0-", 3}}
    ```
  """
  @spec profile_simple(task(), non_neg_integer()) :: :ok
  def profile_simple(pid, n \\ 10000)

  def profile_simple(pid, n) when is_pid(pid) do
    pid = to_pid(pid)

    samples =
      for _ <- 1..n do
        {:current_function, what} = :erlang.process_info(pid, :current_function)
        Process.sleep(1)
        {Time.utc_now(), what}
      end

    ret =
      Enum.reduce(samples, %{}, fn {_time, what}, map ->
        Map.update(map, what, 1, fn n -> n + 1 end)
      end)

    ret = Enum.map(ret, fn {k, v} -> {v, k} end) |> Enum.sort()
    for n <- ret, do: IO.puts("#{inspect(n)}")
    :ok
  end

  def profile_simple(pid, msecs) do
    with_pid(pid, fn pid -> profile_simple(pid, msecs) end, msecs)
  end

  @doc """
    This runs the sampling profiler for the given amount of milliseconds or
    10 seconds by default. The sampling profiler will collect stack traces
    of the given process pid or process name and print the collected samples
    based on frequency.

    For pid there are five different input formats allowed:

    1. fun() which will then be spwaned called in a loop and killed after the test
    2. Native pid()
    3. An atom that is resolved using whereis(name)
    4. A string of the format "<a.b.c>" or "0.b.c" or just "b" in which
       case the pid is interpreted as "<0.b.0>"
    5. An integer, in which case the pid is interpreted as "<0.\#{int}.0>"

    In this example the profiler is used to profile itself. The first percentage
    number shows how many samples were found in the given function call.
    Indention indicates the call stack:
    ```
    iex(2)> Profiler.profile(187)
    100% {:proc_lib, :init_p_do_apply, 3, [file: 'proc_lib.erl', line: 249]}
      100% {IEx.Evaluator, :init, 4, [file: 'lib/iex/evaluator.ex', line: 27]}
        100% {IEx.Evaluator, :loop, 1, [file: 'lib/iex/evaluator.ex', line: 103]}
            100% {IEx.Evaluator, :eval, 3, [file: 'lib/iex/evaluator.ex', line: 217]}
              100% {IEx.Evaluator, :do_eval, 3, [file: 'lib/iex/evaluator.ex', line: 239]}
                  100% {IEx.Evaluator, :handle_eval, 5, [file: 'lib/iex/evaluator.ex', line: 258]}
                    100% {:elixir, :eval_forms, 3, [file: 'src/elixir.erl', line: 263]}
                        100% {:elixir, :recur_eval, 3, [file: 'src/elixir.erl', line: 278]}
                          100% {:erl_eval, :do_apply, 6, [file: 'erl_eval.erl', line: 680]}
                              100% {Profiler, :profile, 2, [file: 'lib/profiler.ex', line: 120]}
                                100% {Enum, :reduce_range_inc, 4, [file: 'lib/enum.ex', line: 3371]}
                                    100% {Profiler, :"-profile/2-fun-0-", 3, [file: 'lib/profiler.ex', line: 121]}
    ```


  """
  @spec profile(task(), non_neg_integer()) :: :ok
  def profile(pid, n \\ 10_000) do
    with_pid(
      pid,
      fn pid ->
        for _ <- 1..n do
          what = stacktrace(pid)
          Process.sleep(1)
          {Time.utc_now(), what}
        end
      end,
      15_000
    )
    |> Enum.reduce(%{}, fn {_time, what}, map ->
      Map.update(map, what, 1, fn n -> n + 1 end)
    end)
    |> Enum.map(fn {k, v} -> {v, Enum.reverse(k)} end)
    |> Enum.sort()
    |> Enum.reduce(%{}, &update/2)
    |> Enum.sort_by(fn {_key, {count, _subtree}} -> count end)
    |> print()

    :ok
  end

  @doc """
    This runs fprof the given amount of milliseconds or 5 seconds by default.

    When the run completes the code tries to open kcachegrind to show the resultung
    kcachegrind file. Ensure to have kcachegrind installed. If kcachgrind is not found
    the function will just return the name of the generated report file. It
    can then be copied to another lcoation for analysis

    For pid there are five different input formats allowed:

    1. fun() which will then be spwaned called in a loop and killed after the test
    2. Native pid()
    3. An atom that is resolved using whereis(name)
    4. A string of the format "<a.b.c>" or "0.b.c" or just "b" in which
       case the pid is interpreted as "<0.b.0>"
    5. An integer, in which case the pid is interpreted as "<0.\#{int}.0>"

    In this example the profiler is used to profile itself. The first percentage
    number shows how many samples were found in the given function call.
    Indention indicates the call stack:
    ```
    iex(1)> Profiler.fprof(fn -> Profiler.demo_fib(30) end)
    ```


  """
  @spec fprof(task(), non_neg_integer()) :: binary()
  def fprof(pid, msecs \\ 5_000) do
    prefix = "profile_#{:rand.uniform(999_999_999)}"

    with_pid(
      pid,
      fn pid ->
        :fprof.trace([:start, {:procs, pid}, {:cpu_time, false}])
        Process.sleep(msecs)
        :fprof.trace(:stop)
        :fprof.profile()
        :fprof.analyse({:dest, String.to_charlist(prefix <> ".fprof")})
      end,
      msecs
    )

    # convert(prefix, %Profiler)
    convert(prefix)
  end

  def memory_usage() do
    percent = fn
      _a, 0 -> "100%"
      a, b -> "#{round(100 * a / b)}%"
    end

    get = fn
      nil, _key ->
        0

      info, key ->
        elem(List.keyfind(info, key, 0, {0, 0}), 1)
    end

    get_alloc = fn
      nil ->
        0

      list ->
        elem(hd(list), 2)
    end

    allocators = [
      :binary_alloc,
      :driver_alloc,
      :eheap_alloc,
      :ets_alloc,
      :exec_alloc,
      :fix_alloc,
      :literal_alloc,
      :ll_alloc,
      :mseg_alloc,
      :sl_alloc,
      :std_alloc,
      :sys_alloc,
      :temp_alloc
    ]

    # ~ special = :erts_mmap

    Enum.each(allocators, fn alloc ->
      info =
        try do
          :erlang.system_info({:allocator, alloc})
        rescue
          _ -> nil
        end

      if is_list(info) do
        {allocated, used, calls} =
          Enum.reduce(info, {0, 0, 0}, fn {:instance, _nr, stats}, {al, us, ca} ->
            allocated = Keyword.get(stats, :mbcs) |> get.(:carriers_size)
            used = Keyword.get(stats, :mbcs) |> get.(:blocks_size)
            calls = Keyword.get(stats, :calls) |> get_alloc.()
            {allocated + al, used + us, calls + ca}
          end)

        waste = allocated - used

        :io.format(
          "~-12s got ~10s used of ~10s alloc (~4s) = ~10s waste @ ~10s calls~n",
          [alloc, "#{used}", "#{allocated}", percent.(used, allocated), "#{waste}", "#{calls}"]
        )
      else
        :io.format("~-12s is disabled~n", [alloc])
      end
    end)
  end

  @spec trace_all_calls(task(), non_neg_integer()) :: binary()
  def trace_all_calls(pid, msecs \\ 5_000) do
    spawn_with_pid(
      pid,
      fn pid ->
        Process.monitor(pid)
        :fprof.trace([:start, {:procs, pid}, {:cpu_time, false}, {:tracer, self()}])
        if is_integer(msecs), do: Process.send_after(self(), {:stop, pid}, msecs)
        calltracer(pid)
      end,
      msecs
    )
  end

  defp calltracer(pid) do
    receive do
      {:DOWN, _ref, :process, ^pid, _reason} ->
        :fprof.trace(:stop)

      {:stop, ^pid} ->
        :fprof.trace(:stop)

      {:trace_ts, ^pid, :call, func, _cp, _timing} ->
        IO.puts("#{inspect(pid)}: #{inspect(func)}")
        calltracer(pid)

      _other ->
        calltracer(pid)
    end
  end

  @spec trace_poll_stacktrace(task(), non_neg_integer()) :: binary()
  def trace_poll_stacktrace(pid, msecs \\ 5_000) do
    spawn_with_pid(
      pid,
      fn pid ->
        Process.monitor(pid)
        if is_integer(msecs), do: Process.send_after(self(), {:stop, pid}, msecs)
        polltracer(pid)
      end,
      msecs
    )
  end

  defp polltracer(pid) do
    receive do
      {:DOWN, _ref, :process, ^pid, _reason} -> :ok
      {:stop, ^pid} -> :ok
      _other -> polltracer(pid)
    after
      500 ->
        with {:current_stacktrace, what} <- :erlang.process_info(pid, :current_stacktrace) do
          what = Enum.take(what, 3)
          IO.puts("#{inspect(pid)}: #{inspect(what)}")
        end

        polltracer(pid)
    end
  end

  @doc """
    Returns current stacktrace for the given pid and allows setting the erlang
    internal stacktrace depth.
  """
  def stacktrace(pid \\ nil, depth \\ 30) do
    :erlang.system_flag(:backtrace_depth, depth)
    pid = to_pid(pid) || self()

    with {:current_stacktrace, [_ | what]} <- :erlang.process_info(pid, :current_stacktrace) do
      what
    else
      _ -> []
    end
  end

  def format_stacktrace(pid \\ nil, depth \\ 30) do
    pid = to_pid(pid) || self()

    case stacktrace(pid, depth) do
      [_ | trace] -> "Stacktrace for #{inspect(pid)}\n" <> Exception.format_stacktrace(trace)
      _ -> "No stacktrace for #{inspect(pid)}"
    end
  end

  def print_stacktrace(pid \\ nil, depth \\ 30) do
    IO.puts(format_stacktrace(pid, depth))
  end

  @doc """
  In order to identify processes that are supposed to be short-lived but actually
  take too mich time this function produces Logger.warning() with a stacktrace if
  the provided process is still alive after the given timeout.

  If the process is just running a certain critical section that should be monitored
  the warning can be supressed using `cancel_warn_if_stuck()`



  @pid Pid of the process to be monitored, or a function after which the warning will be autocancelled
  @opts can be
    - `timeout` -> Timeout in ms after which the warning will be produced. defaults to 5_000
    - `label` -> Process label to be used in the report or just the `pid` will be used
    - `fun` -> When provided this function replaces the default report via `Logger.warning`

  """
  def warn_if_stuck(pid, opts \\ [])

  def warn_if_stuck(fun, opts) when is_function(fun) do
    ref = warn_if_stuck(self(), opts)
    ret = fun.()
    cancel_warn_if_stuck(ref)
    ret
  end

  def warn_if_stuck(pid, opts) do
    pid = to_pid(pid) || self()
    timeout = Keyword.get(opts, :timeout, 5_000)
    fun = Keyword.get(opts, :fun, nil)
    label = Keyword.get(opts, :label, "Process #{inspect(pid)}")

    spawn(fn ->
      Process.monitor(pid)

      receive do
        {:DOWN, _ref, :process, _object, _reason} ->
          :ok

        :cancel ->
          :ok
      after
        timeout ->
          if fun do
            fun.()
          else
            Logger.warning("#{label} stuck for #{timeout}\n" <> format_stacktrace(pid))
          end
      end
    end)
  end

  def cancel_warn_if_stuck(pid) do
    if pid != nil do
      send(pid, :cancel)
    end
  end

  @doc """
    Demo function for the documentation.
    Never implement fibonacci like this. Never
  """
  @spec demo_fib(integer()) :: pos_integer
  def demo_fib(n) do
    if n < 2 do
      1
    else
      demo_fib(n - 1) + demo_fib(n - 2)
    end
  end

  # ===========================                    ===========================
  # =========================== INTERNAL FUNCTIONS ===========================
  # ===========================                    ===========================

  def convert(prefix) do
    source = String.to_charlist(prefix <> ".fprof")
    destination = prefix <> ".cprof"
    {:ok, file} = :file.open(String.to_charlist(destination), [:write])
    {:ok, terms} = :file.consult(source)
    :io.format(file, "events: Time~n", [])
    process_terms(file, terms, [])
    :file.delete(source)

    (System.find_executable("kcachegrind") || System.find_executable("qcachegrind"))
    |> case do
      nil ->
        IO.puts("Run kcachegrind #{destination}")

      bin ->
        spawn(fn -> System.cmd(bin, [destination], stderr_to_stdout: true) end)
    end

    destination
  end

  defstruct [:pid, :in_file, :in_file_format, :out_file]

  defp process_terms(file, [], _opts) do
    :file.close(file)
  end

  defp process_terms(file, [{:analysis_options, _opt} | rest], opts) do
    process_terms(file, rest, opts)
  end

  defp process_terms(file, [[{:totals, _count, acc, _own}] | rest], opts) do
    :io.format(file, "summary: ~w~n", [:erlang.trunc(acc * 1000)])
    process_terms(file, rest, opts)
  end

  defp process_terms(file, [[{pid, _count, _acc, _own} | _T] | rest], opts = %Profiler{pid: true})
       when is_list(pid) do
    :io.format(file, "ob=~s~n", [pid])
    process_terms(file, rest, opts)
  end

  defp process_terms(file, [list | rest], opts) when is_list(list) do
    process_terms(file, rest, opts)
  end

  defp process_terms(file, [entry | rest], opts) do
    process_entry(file, entry)
    process_terms(file, rest, opts)
  end

  defp process_entry(file, {_calling_list, actual, called_list}) do
    process_actual(file, actual)
    process_called_list(file, called_list)
  end

  defp process_actual(file, {func, _count, _acc, own}) do
    file_name = get_file(func)
    :io.format(file, "fl=~s~n", [file_name])
    :io.format(file, "fn=~w~n", [func])
    :io.format(file, "1 ~w~n", [trunc(own * 1000)])
  end

  defp process_called_list(_, []) do
    :ok
  end

  defp process_called_list(file, [called | rest]) do
    process_called(file, called)
    process_called_list(file, rest)
  end

  defp process_called(file, {func, count, acc, _own}) do
    file_name = get_file(func)
    :io.format(file, "cfl=~s~n", [file_name])
    :io.format(file, "cfn=~w~n", [func])
    :io.format(file, "calls=~w 1~n", [count])
    :io.format(file, "1 ~w~n", [trunc(acc * 1000)])
  end

  defp get_file({mod, _func, _arity}) do
    case Atom.to_string(mod) do
      "Elixir." <> rest ->
        name = Macro.underscore(rest)
        String.to_charlist(Path.join(["lib", "#{name}.ex"]))

      _ ->
        ~c"src/#{mod}.erl"
    end
  end

  defp get_file(_func) do
    ~c"pseudo"
  end

  defp print(tree) do
    sum = Enum.reduce(tree, 0, fn {_, {count, _}}, sum -> sum + count end)
    print(0, tree, sum / 20)
  end

  defp print(level, tree, min) do
    prefix = level * 3

    for {key, {count, subtree}} <- tree do
      if count > min do
        count = round(count * 5 / min) |> Integer.to_string()
        IO.puts("#{count |> String.pad_leading(4 + prefix)}% #{inspect(key)}")
        print(level + 1, subtree, min)
      end
    end
  end

  defp update({_count, []}, map) do
    map
  end

  defp update({count, [head | list]}, map) do
    {nil, map} =
      Map.get_and_update(map, head, fn
        {c, tree} ->
          {nil, {c + count, update({count, list}, tree)}}

        nil ->
          {nil, {count, update({count, list}, %{})}}
      end)

    map
  end

  defp to_pid(pid) when is_binary(pid) do
    case String.first(pid) do
      "0" -> "<#{pid}>"
      "<" -> pid
      _ -> "<0.#{pid}.0>"
    end
    |> :erlang.binary_to_list()
    |> :erlang.list_to_pid()
  end

  defp to_pid(pid) when is_atom(pid) do
    Process.whereis(pid) || find_pid(pid, 10)
  end

  defp to_pid(pid) when is_integer(pid) do
    to_pid("<0.#{pid}.0>")
  end

  defp to_pid(pid) when is_tuple(pid) do
    find_pid(pid, 10)
  end

  defp to_pid(pid) do
    pid
  end

  @doc """
  Converts a term to a pid.
  Accepts
  - pid()
  - integer()
  - tuple()
  - atom()
  - binary()
  - string()

  Examples:
  ```
  iex(1)> Profiler.pid(1)
  <0.1.0>
  iex(2)> Profiler.pid("1")
  <0.1.0>
  iex(3)> Profiler.pid("Elixir.IEx.Evaluator")
  <0.187.0>
  iex(4)> Profiler.pid({:IEx.Evaluator, :init, 4})
  """
  @spec pid(term()) :: pid()
  def pid(term) do
    to_pid(term)
  end

  defp find_pid(_needle, 0), do: nil

  defp find_pid(needle, n) do
    IO.puts("to_pid '#{inspect(needle)}' looking for matching process... (#{n})")

    :erlang.processes()
    |> Enum.reject(fn pid -> pid == self() end)
    |> Enum.shuffle()
    |> Enum.find(fn pid ->
      info = :erlang.process_info(pid)

      if process_name(info) == needle do
        IO.puts("to_pid '#{inspect(pid)}' found #{inspect(pid)}")
        IO.puts("info: #{inspect(info)}")
        pid
      end
    end)
    |> case do
      nil ->
        Process.sleep(100)
        find_pid(needle, n - 1)

      pid ->
        pid
    end
  end

  defp spawn_with_pid(pid, fun, msecs) do
    spawn(fn -> with_pid(pid, fun, msecs) end)
  end

  defp with_pid(pid, fun, msecs) when is_function(pid) do
    pid = spawn_link(fn -> looper(pid, msecs) end)
    ret = fun.(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    ret
  end

  defp with_pid(pid, fun, _) do
    fun.(to_pid(pid) || raise("No such pid #{inspect(pid)}"))
  end

  defp looper(fun, msecs) do
    if msecs > 0 do
      time = elem(:timer.tc(fn -> fun.() end), 0)
      IO.puts("loop time: #{time}")
      looper(fun, msecs - div(time, 1000))
    end
  end
end

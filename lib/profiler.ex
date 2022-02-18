defmodule Profiler do
  @moduledoc """
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
    Processes lists all processes ordered by reductions withing the given
    timeout. For that it takes an initial snapshot, sleeps the given timeout
    and takes a second snapshot.

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
  @spec processes(non_neg_integer()) :: :ok
  def processes(timeout \\ 5_000) do
    pids = :erlang.processes()
    info1 = Enum.map(pids, &:erlang.process_info/1)
    Process.sleep(timeout)
    info2 = Enum.map(pids, &:erlang.process_info/1)

    info =
      Enum.zip([pids, info1, info2])
      |> Enum.reject(fn {_pid, info1, info2} -> info1 == :undefined or info2 == :undefined end)
      |> Enum.map(fn {pid, info1, info2} ->
        name =
          if info2[:registered_name] == nil do
            if info2[:dictionary] == nil or info2[:dictionary][:"$initial_call"] == nil do
              info2[:initial_call]
            else
              info2[:dictionary][:"$initial_call"]
            end
          else
            info2[:registered_name]
          end

        [
          {:pid, pid},
          {:reductionsd, info2[:reductions] - info1[:reductions]},
          {:name, name}
          | info2
        ]
      end)
      |> Enum.sort(&(&1[:reductionsd] > &2[:reductionsd]))
      |> Enum.take(10)

    for n <- info do
      :io.format("~p~n", [[n[:pid], n[:name], n[:reductionsd]]])
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
    with_pid(pid, fn pid -> profile_simple(pid, msecs) end)
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
    with_pid(pid, fn pid ->
      for _ <- 1..n do
        what = stacktrace(pid)
        Process.sleep(1)
        {Time.utc_now(), what}
      end
    end)
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

    with_pid(pid, fn pid ->
      :fprof.trace([:start, {:procs, pid}, {:cpu_time, false}])
      Process.sleep(msecs)
      :fprof.trace(:stop)
      :fprof.profile()
      :fprof.analyse({:dest, String.to_charlist(prefix <> ".fprof")})
    end)

    # convert(prefix, %Profiler)
    convert(prefix)
  end

  @spec trace_all_calls(task(), non_neg_integer()) :: binary()
  def trace_all_calls(pid, msecs \\ 5_000) do
    spawn_with_pid(pid, fn pid ->
      Process.monitor(pid)
      :fprof.trace([:start, {:procs, pid}, {:cpu_time, false}, {:tracer, self()}])
      if is_integer(msecs), do: Process.send_after(self(), {:stop, pid}, msecs)
      calltracer(pid)
    end)
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
    spawn_with_pid(pid, fn pid ->
      Process.monitor(pid)
      if is_integer(msecs), do: Process.send_after(self(), {:stop, pid}, msecs)
      polltracer(pid)
    end)
  end

  defp polltracer(pid) do
    receive do
      {:DOWN, _ref, :process, ^pid, _reason} -> :ok
      {:stop, ^pid} -> :ok
      _other -> polltracer(pid)
    after
      500 ->
        {:current_stacktrace, what} = :erlang.process_info(pid, :current_stacktrace)
        what = Enum.take(what, 3)
        IO.puts("#{inspect(pid)}: #{inspect(what)}")
        polltracer(pid)
    end
  end

  @doc """
    Returns current stacktrace for the given pid and allows setting the erlang
    internal stacktrace depth.
  """
  def stacktrace(pid \\ nil, depth \\ 30) do
    :erlang.system_flag(:backtrace_depth, depth)
    pid = pid || self()
    {:current_stacktrace, what} = :erlang.process_info(pid, :current_stacktrace)
    what
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
    destination = prefix <> ".cprof"
    {:ok, file} = :file.open(String.to_charlist(destination), [:write])
    {:ok, terms} = :file.consult(String.to_charlist(prefix <> ".fprof"))
    :io.format(file, "events: Time~n", [])
    process_terms(file, terms, [])

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
    :io.format(file, "fl=~w~n", [file_name])
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
    :io.format(file, "cfl=~w~n", [file_name])
    :io.format(file, "cfn=~w~n", [func])
    :io.format(file, "calls=~w 1~n", [count])
    :io.format(file, "1 ~w~n", [trunc(acc * 1000)])
  end

  defp get_file({mod, _func, _arity}) do
    mod
  end

  defp get_file(_func) do
    :pseudo
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
    :erlang.whereis(pid)
  end

  defp to_pid(pid) when is_integer(pid) do
    to_pid("<0.#{pid}.0>")
  end

  defp to_pid(pid) do
    pid
  end

  defp spawn_with_pid(pid, fun) do
    spawn(fn -> with_pid(pid, fun) end)
  end

  defp with_pid(pid, fun) when is_function(pid) do
    pid = spawn_link(fn -> looper(pid) end)
    ret = fun.(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    ret
  end

  defp with_pid(pid, fun) do
    fun.(to_pid(pid))
  end

  defp looper(fun) do
    fun.()
    looper(fun)
  end
end

defmodule Waterpark.Pool do
  require Logger
  use GenServer

  @moduledoc """
    Implementation of process pool using GenServer.
    Ability to start workers either synchronously
    or asynchronously (queueing and running when ready)
    TODO Add function to query number of free workers
  """

  @registry_name Registry.Pool

  @doc """
    Internal state for the Pool.
    Tracks:
     the number of free workers available in the pool,
     this pool's lifeguard pid (used for adding a new worker to it's supervision tree),
     running worker references,
     a queue of "to be scheduled" workers yet to run.
  """
  defstruct [
    :pool_name,
    :free_workers,
    :lifeguard_pid,
    worker_refs: MapSet.new(),
    queue: :queue.new()
  ]

  @doc """
    Starts the pool with:
      pool_name: The name of this pool
      worker_limit: the maximum number of workers this pool is allowed
      supervisor_pid: This pool's supervisor (used to start the lifeguard)
      worker_mfa: The type of worker in this pool
  """
  def start_link([pool_name, worker_limit, supervisor_pid, worker_mfa]) do
    Logger.info(fn -> "Starting pool: #{pool_name}" end)

    GenServer.start_link(
      __MODULE__,
      [pool_name, worker_limit, supervisor_pid, worker_mfa],
      name: via_registry(pool_name)
    )
  end

  @doc """
    Runs a new worker in pool "pool_name"
    Will return {:ok, worker_pid} if this worker has been successfully started
    or {:error, "No free workers"} if there isn't enough room in the pool
  """
  def run(pool_name, args) do
    GenServer.call(via_registry(pool_name), {:run, args})
  end

  @doc """
    Initializes this pools lifeguard, by placing it under this pool's
    supervsor's supervision tree
  """
  def init([pool_name, worker_limit, supervisor_pid, worker_mfa]) do
    send(self(), {:init_lifeguard, {supervisor_pid, worker_mfa}})
    # Initialize our state with the number of free workers == worker limit.
    state = %Waterpark.Pool{pool_name: pool_name, free_workers: worker_limit}
    {:ok, state}
  end

  @doc """
    Callback for :run when we have enough room in the pool to allocate (limit not reached)
  """
  def handle_call(
        {:run, args},
        _From,
        %Waterpark.Pool{
          free_workers: free_workers,
          worker_refs: refs,
          lifeguard_pid: lifeguard_pid
        } = state
      )
      when free_workers > 0 do
    Logger.info(fn -> "Starting worker with #{inspect(args)} args" end)
    {:ok, worker_pid} = Supervisor.start_child(lifeguard_pid, args)
    ref = Process.monitor(worker_pid)
    Logger.debug(fn -> "Worker started with ref: #{inspect(ref)} pid: #{inspect(worker_pid)}" end)

    state = %Waterpark.Pool{
      state
      | worker_refs: MapSet.put(refs, ref),
        free_workers: free_workers - 1
    }

    Logger.debug(fn -> "#{state.pool_name} now has #{state.free_workers} workers available" end)
    {:reply, {:ok, worker_pid}, state}
  end

  @doc """
    When we have no free workers for a run, reply with :error
  """
  def handle_call({:run, _args}, _From, %Waterpark.Pool{free_workers: free_workers} = state)
      when free_workers <= 0 do
    Logger.warn(fn -> "#{state.pool_name} does not have any free workers" end)
    {:reply, {:error, "No free workers"}, state}
  end

  @doc """
    Initializes the pool's lifeguard, storing it's pid in state so as to start workers later.
  """
  def handle_info({:init_lifeguard, {supervisor_pid, worker_mfa}}, state) do
    Logger.info(fn ->
      "Starting #{inspect(state.pool_name)} lifeguard with #{inspect(worker_mfa)}"
    end)

    child_spec = Supervisor.child_spec({Waterpark.Lifeguard, worker_mfa}, restart: :temporary)

    {:ok, pid} = Supervisor.start_child(supervisor_pid, child_spec)
    Process.link(pid)
    {:noreply, %Waterpark.Pool{state | lifeguard_pid: pid}}
  end

  @doc """
    When a worker terminates (successfully or not) we need to remove it's reference
    from state.worker_refs, and increment free_workers
  """
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    %Waterpark.Pool{worker_refs: worker_refs} = state

    case MapSet.member?(worker_refs, ref) do
      true -> process_down_worker(ref, state)
      false -> {:noreply, state}
    end
  end

  @doc """
    Catch all for unknown messages
  """
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp process_down_worker(ref, state) do
    Logger.debug(fn -> "Worker #{inspect(ref)} finished" end)
    # For :run calls we just remove the ref from worker_refs and inc free_workers
    %Waterpark.Pool{worker_refs: worker_refs, free_workers: free_workers} = state
    worker_refs = MapSet.delete(worker_refs, ref)
    state = %Waterpark.Pool{state | worker_refs: worker_refs, free_workers: free_workers + 1}
    Logger.debug(fn -> "#{state.pool_name} now has #{state.free_workers} workers available" end)
    {:noreply, state}
  end

  defp via_registry(name) do
    {:via, Registry, {@registry_name, name}}
  end

  def registry_name do
    @registry_name
  end
end
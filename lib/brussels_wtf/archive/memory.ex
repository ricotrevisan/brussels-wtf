defmodule BrusselsWtf.Archive.Memory do
  @moduledoc false
  @behaviour BrusselsWtf.Archive

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  @impl true
  def put(namespace, sha256, bytes) do
    key = BrusselsWtf.Archive.object_key(sha256, namespace)

    Agent.get_and_update(__MODULE__, fn objects ->
      case Map.fetch(objects, key) do
        :error -> {{:ok, key}, Map.put(objects, key, bytes)}
        {:ok, ^bytes} -> {{:ok, key}, objects}
        {:ok, _different_bytes} -> {{:error, :content_address_collision}, objects}
      end
    end)
  end

  @impl true
  def put_file(namespace, sha256, path, size) do
    with {:ok, bytes} <- File.read(path),
         :ok <- verify_bytes(bytes, sha256, size) do
      put(namespace, sha256, bytes)
    end
  end

  @impl true
  def verify_file(object_key, sha256, size) do
    with {:ok, bytes} <- get(object_key) do
      verify_bytes(bytes, sha256, size)
    end
  end

  defp verify_bytes(bytes, expected_sha256, expected_size) do
    actual_sha256 = BrusselsWtf.Digest.sha256(bytes)
    actual_size = byte_size(bytes)

    cond do
      actual_size != expected_size ->
        {:error, {:size_mismatch, expected_size, actual_size}}

      actual_sha256 != expected_sha256 ->
        {:error, {:hash_mismatch, expected_sha256, actual_sha256}}

      true ->
        :ok
    end
  end

  @impl true
  def ready?, do: :ok

  @impl true
  def get(object_key) do
    case Agent.get(__MODULE__, &Map.fetch(&1, object_key)) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_found}
    end
  end
end

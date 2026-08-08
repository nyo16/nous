defmodule Nous.HTTP.StreamBackend.ReqSaturationTest do
  # async: false — Nous.TaskSupervisorSaturation drops the VM-wide
  # Nous.TaskSupervisor ceiling for the duration of each test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Nous.HTTP.StreamBackend.Req
  alias Nous.StreamNormalizer
  alias Nous.TaskSupervisorSaturation

  # Req is the DEFAULT streaming backend for every provider, and it holds one
  # task for a stream's whole duration — so `:max_children` is really the ceiling
  # on concurrent streams. The producer is spawned inside `Stream.resource/3`'s
  # start_fun, which means a refused spawn used to raise a bare RuntimeError in
  # whichever process first enumerated the stream (documented as a LiveView),
  # arbitrarily far from the `stream/4` that built it.
  #
  # What these pin is that the refusal arrives as DATA, in-band, in the same
  # shape as every other transport failure this backend reports.

  # Never contacted: the producer task is refused before a request is built.
  @unused_url "http://127.0.0.1:1/v1/sse"

  test "a refused producer task yields {:stream_error, %{reason: :saturated}} and halts" do
    TaskSupervisorSaturation.saturate!()

    # stream/4 still succeeds. Construction cannot know — the task is only
    # spawned once a consumer starts enumerating, in the consumer's process.
    assert {:ok, stream} = Req.stream(@unused_url, %{model: "x"}, [], [])

    {events, log} = with_log(fn -> Enum.to_list(stream) end)

    # Exactly one event proves two things at once: enumeration did not raise,
    # and the stream halted after the first {:stream_error, _} as
    # Nous.HTTP.StreamBackend requires of every backend.
    assert events == [{:stream_error, %{reason: :saturated}}]
    assert log =~ "task_supervisor_max_children"
  end

  test "the refusal reaches a consumer as {:error, _} through the normalizer" do
    TaskSupervisorSaturation.saturate!()

    {:ok, stream} = Req.stream(@unused_url, %{}, [], [])
    {events, _log} = with_log(fn -> stream |> StreamNormalizer.normalize() |> Enum.to_list() end)

    # This is the shape provider code and LiveViews actually match on, and it is
    # the same one a 500 or a connect failure produces.
    assert events == [{:error, %{reason: :saturated}}]
  end

  test "halting a refused stream early still runs cleanup with no task to shut down" do
    TaskSupervisorSaturation.saturate!()

    {:ok, stream} = Req.stream(@unused_url, %{}, [], [])

    # Enum.take/2 forces Stream.resource's after-fun. cleanup/1 must take its
    # `task: nil` clause here; Task.shutdown(nil) would raise instead.
    {events, _log} = with_log(fn -> Enum.take(stream, 1) end)

    assert events == [{:stream_error, %{reason: :saturated}}]
  end
end

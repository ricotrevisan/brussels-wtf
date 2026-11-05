defmodule BrusselsWtf.Workers.PublishMeetingTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.Workers.PublishMeeting

  test "retries wait long enough for a provider rate limit to clear" do
    assert PublishMeeting.backoff(%Oban.Job{attempt: 1}) == 60
    assert PublishMeeting.backoff(%Oban.Job{attempt: 2}) == 240
  end

  test "each job is its own paid generation" do
    assert PublishMeeting.generation_ref(%Oban.Job{id: 42}) == "oban:42"
    assert PublishMeeting.generation_ref(%Oban.Job{id: nil}) == nil
  end
end

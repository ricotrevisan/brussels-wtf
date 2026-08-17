defmodule BrusselsWtf.Review do
  @moduledoc """
  Actionable domain ambiguity, distinct from Oban transport state.
  """

  use Ash.Domain, otp_app: :brussels_wtf

  resources do
    resource BrusselsWtf.Review.Case do
      define :open_review_case, action: :open
    end
  end
end

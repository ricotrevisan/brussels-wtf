defmodule BrusselsWtf.Identity.PublicProfile do
  @moduledoc "Closed, redacted company and person profile results for public callers."

  defmodule CbeCitation do
    @moduledoc false

    @enforce_keys [:published_on, :sha256]
    defstruct @enforce_keys
  end

  defmodule Company do
    @moduledoc false

    @enforce_keys [
      :entity_id,
      :registered_name,
      :enterprise_number,
      :status,
      :cbe,
      :relationships
    ]
    defstruct @enforce_keys
  end

  defmodule Person do
    @moduledoc false

    @enforce_keys [:id, :legal_name, :relationships]
    defstruct @enforce_keys
  end

  defmodule Redirect do
    @moduledoc false

    @enforce_keys [:kind, :target_id]
    defstruct @enforce_keys
  end
end

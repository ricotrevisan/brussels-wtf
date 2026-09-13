defmodule BrusselsWtfWeb.FollowControl do
  use Phoenix.Component

  def load(conn) do
    follows =
      case BrusselsWtf.Accounts.authenticate_session(
             Plug.Conn.get_session(conn, :citizen_session_id)
           ) do
        {:ok, citizen} -> BrusselsWtf.Follow.citizen_follows(citizen)
        _ -> []
      end

    conn
    |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
    |> Plug.Conn.assign(
      :citizen_follows,
      Map.new(follows, &{{to_string(&1.target_type), &1.target_identifier}, &1})
    )
  end

  def find(follows, type, identifier), do: Map.get(follows, {to_string(type), identifier})
  def action(nil), do: "/citizen/feed/follows"
  def action(follow), do: "/citizen/feed/follows/#{follow.id}/remove"

  attr :follow, :any, required: true
  attr :locale, :string, required: true
  attr :type, :string, default: ""
  attr :identifier, :string, default: ""
  attr :label, :string, default: ""
  attr :show_history, :boolean, default: true

  def control(assigns) do
    ~H"""
    <div class="mt-4">
      <p :if={@follow} class="text-sm" data-followed-state>{text(@locale, :following)}</p>
      <form method="post" action={action(@follow) <> "?lang=" <> @locale}>
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="hidden" name="target_type" value={@type} />
        <input type="hidden" name="target_identifier" value={@identifier} />
        <button type="submit" class="btn btn-sm" data-follow-control data-unfollow-control={!!@follow}>
          {if @follow, do: text(@locale, :unfollow), else: @label}
        </button>
      </form>
      <p :if={@follow && @show_history} class="mt-2 text-sm">{text(@locale, :history)}</p>
    </div>
    """
  end

  def html(follow, locale) do
    control(%{
      follow: follow,
      locale: locale,
      type: "",
      identifier: "",
      label: "",
      show_history: false,
      __changed__: nil
    })
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  def text("fr", :following), do: "Suivi actif"
  def text("nl", :following), do: "Je volgt dit"
  def text(_, :following), do: "Following"
  def text("fr", :unfollow), do: "Ne plus suivre"
  def text("nl", :unfollow), do: "Niet meer volgen"
  def text(_, :unfollow), do: "Unfollow"

  def text("fr", :history),
    do:
      "Le désabonnement arrête les nouvelles mises à jour. Les mises à jour déjà reçues et leur état de lecture sont conservés jusqu’à leur expiration habituelle de 12 mois."

  def text("nl", :history),
    do:
      "Als je stopt met volgen, ontvang je geen nieuwe updates meer. Ontvangen updates en hun leesstatus blijven bewaard tot hun gebruikelijke vervaldatum na 12 maanden."

  def text(_, :history),
    do:
      "Unfollowing stops new updates. Updates already received and their read state are kept until their normal 12-month expiry."
end

defmodule BrusselsWtf.ProviderCredit do
  @moduledoc """
  Watches the paid coverage provider's credit and resumes pages it stranded.

  There is no app-side spending limit when `COVERAGE_MONTHLY_BUDGET_CENTS` is unset;
  the OpenRouter account and key limits are the ceiling (ADR 0007). This check runs
  hourly and right after a call is refused with HTTP 402. It alerts Rico on Discord
  through Drummer once per change of state (low, exhausted, recovered), and once
  credit is back it queues one new publish job for each page whose open publication
  case says the provider was out of credit. Those jobs reuse the locales that already
  succeeded (issue 159), so only the missing work is paid for.
  """

  require Ash.Query
  require Logger

  alias BrusselsWtf.Council
  alias BrusselsWtf.Council.{GenerationControl, ProviderCreditCheck}
  alias BrusselsWtf.Processors.OpenRouterCoverage

  @provider "openrouter"
  @default_low_cents 500
  @top_up "https://openrouter.ai/settings/credits"

  @doc "Queues one check soon; repeated requests within a minute collapse into one."
  def request_check(trigger) when is_binary(trigger) do
    %{trigger: trigger}
    |> BrusselsWtf.Workers.CheckProviderCredit.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc "Runs one check. Does nothing unless paid OpenRouter generation is configured."
  @spec check(String.t(), keyword()) :: {:ok, ProviderCreditCheck.t()} | :skipped
  def check(trigger, opts \\ []) do
    if GenerationControl.mode() == :paid and
         Application.get_env(:brussels_wtf, :coverage_processor) == OpenRouterCoverage do
      balance = Keyword.get_lazy(opts, :balance, &OpenRouterCoverage.credit_balance/0)
      {:ok, run_check(trigger, balance)}
    else
      :skipped
    end
  end

  defp run_check(trigger, balance) do
    previous = previous_notified_level()
    remaining = remaining_cents(balance)
    level = level(remaining, trigger)
    waiting = stranded_meeting_ids()

    resumed = if level == :ok, do: resume(waiting), else: 0

    notified =
      case alert_for(previous, level, remaining, balance, length(waiting), resumed) do
        nil ->
          if level == :unavailable, do: previous, else: notified_after(previous, level)

        message ->
          case BrusselsWtf.Alerts.Drummer.notify(message, alert_id(level)) do
            :ok -> level
            {:error, _reason} -> previous
          end
      end

    Council.record_provider_credit_check!(%{
      provider: @provider,
      trigger: trigger,
      level: level,
      notified_level: notified,
      key_remaining_cents: key_value(balance, :key_remaining_cents),
      account_remaining_cents: key_value(balance, :account_remaining_cents),
      resumed_pages: resumed
    })
  end

  # A 402 means the provider refused to bill, whatever the balance endpoint says.
  defp level(_remaining, "payment_required"), do: :exhausted
  defp level(nil, _trigger), do: :unavailable
  defp level(remaining, _trigger) when remaining <= 0, do: :exhausted

  defp level(remaining, _trigger) do
    if remaining < low_threshold_cents(), do: :low, else: :ok
  end

  defp notified_after(previous, level) when level in [:ok, :low, :exhausted] do
    if level == previous, do: previous, else: level
  end

  defp alert_for(previous, level, _remaining, _balance, _waiting, _resumed)
       when level == previous or level == :unavailable,
       do: nil

  defp alert_for(_previous, :low, remaining, balance, _waiting, _resumed),
    do:
      "brussels.wtf: OpenRouter credit is low, #{usd(remaining)} left#{detail(balance)}. " <>
        "Top up before new meetings stop publishing: #{@top_up}"

  defp alert_for(_previous, :exhausted, _remaining, balance, waiting, _resumed),
    do:
      "brussels.wtf: OpenRouter refused a paid call: out of credit#{detail(balance)}. " <>
        "#{pages(waiting)} waiting and will publish on their own once credit is back: #{@top_up}"

  defp alert_for(previous, :ok, remaining, _balance, _waiting, resumed)
       when previous in [:low, :exhausted],
       do:
         "brussels.wtf: OpenRouter credit is back, #{usd(remaining)} left. " <>
           "Resuming #{pages(resumed)}."

  defp alert_for(_previous, _level, _remaining, _balance, _waiting, _resumed), do: nil

  defp resume(meeting_ids) do
    Enum.count(meeting_ids, fn meeting_id ->
      match?(
        {:ok, _job},
        Oban.insert(BrusselsWtf.Workers.PublishMeeting.new(%{"meeting_id" => meeting_id}))
      )
    end)
  end

  @doc "Meetings whose open publication case says the provider was out of credit."
  def stranded_meeting_ids do
    classification = BrusselsWtf.Council.Publication.credit_exhausted_classification()

    BrusselsWtf.Repo.query!(
      """
      SELECT DISTINCT mp.council_meeting_id::text
      FROM review_cases r JOIN meeting_pages mp ON mp.id = r.affected_record_id
      WHERE r.kind = 'publication' AND r.status = 'open'
        AND r.diagnostics->>'classification' = $1
      ORDER BY 1
      """,
      [classification]
    ).rows
    |> List.flatten()
  end

  defp previous_notified_level do
    case Ash.read_one(
           Ash.Query.for_read(ProviderCreditCheck, :latest, %{provider: @provider}),
           domain: Council
         ) do
      {:ok, %{notified_level: level}} -> level
      _none -> :ok
    end
  end

  defp remaining_cents({:ok, %{account_remaining_cents: account} = balance}) do
    [account, balance[:key_remaining_cents]] |> Enum.reject(&is_nil/1) |> Enum.min()
  end

  defp remaining_cents(_balance), do: nil

  defp key_value({:ok, balance}, key), do: Map.get(balance, key)
  defp key_value(_balance, _key), do: nil

  defp detail({:ok, %{key_remaining_cents: key, account_remaining_cents: account}})
       when is_integer(key),
       do: " (account #{usd(account)}, API key limit #{usd(key)})"

  defp detail({:ok, %{account_remaining_cents: account}}), do: " (account #{usd(account)})"
  defp detail(_balance), do: ""

  defp pages(1), do: "1 meeting page"
  defp pages(count), do: "#{count} meeting pages"

  defp usd(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)
    "#{sign}$#{div(cents, 100)}.#{String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")}"
  end

  defp usd(_cents), do: "unknown"

  # One alert per state per hour; a retried delivery in that hour is deduplicated.
  defp alert_id(level) do
    hour = DateTime.utc_now() |> DateTime.truncate(:second) |> Calendar.strftime("%Y%m%d%H")
    "brussels-wtf-credit-#{level}-#{hour}"
  end

  defp low_threshold_cents,
    do: Application.get_env(:brussels_wtf, :provider_credit_low_cents, @default_low_cents)
end

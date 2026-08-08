defmodule Nous.Tools.DateTimeTools do
  @moduledoc """
  Built-in tools for date and time operations.

  These tools provide common date/time functionality that AI agents often need:
  - Get current date/time in various formats
  - Parse and format dates
  - Calculate date differences
  - Check business days and weekends

  ## Timezones

  Every "current" tool accepts a `timezone` argument, but nous declares no
  time zone database dependency, so Elixir's built-in
  `Calendar.UTCOnlyTimeZoneDatabase` is the only one available and `"Etc/UTC"`
  is the only zone it can resolve. `"UTC"` is accepted as an alias for it,
  because a model produces that spelling constantly and it is unambiguous.
  Any other zone returns an error map naming the supported set rather than
  raising out of the tool call — the argument is model-supplied, so an
  unsupported value is an expected input, not a fault. Add `:tzdata` and set
  `config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase` in the host
  application to widen it; nothing here needs to change.

  ## Usage

      agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        tools: [
          &DateTimeTools.current_date/2,
          &DateTimeTools.current_time/2,
          &DateTimeTools.current_datetime/2
        ]
      )

      {:ok, result} = Nous.run(agent, "What day is today?")
  """

  # The only zone Elixir's built-in Calendar.UTCOnlyTimeZoneDatabase resolves.
  @utc_zone "Etc/UTC"
  # "UTC" is the spelling a model reaches for and means exactly @utc_zone, so
  # it is aliased rather than refused. Everything else is refused, because
  # DateTime.now!/1 raises for it and the argument is model-supplied.
  @supported_timezones ["UTC", @utc_zone]

  # Every tool in this module ignores the run context — the parameter exists
  # only to satisfy the two-arity shape the tool executor calls. Callers that
  # have no context (tests, direct use) pass `nil`.
  @type ctx :: Nous.RunContext.t() | nil

  @typedoc """
  What a timezone-aware tool returns *instead of* its result map when the model
  asks for a zone this build cannot resolve. Produced by the with_timezone/2
  helper below, which every timezone-aware tool routes through.
  """
  @type timezone_error :: %{
          error: String.t(),
          timezone: term(),
          supported_timezones: [String.t()]
        }

  @doc """
  Get the current date in the specified format.

  ## Arguments

  - format: "iso8601" (default), "us" (MM/DD/YYYY), "eu" (DD/MM/YYYY), "full" (Monday, January 1, 2025)
  - timezone: "Etc/UTC" (default), or its alias "UTC". Any other zone returns an error.
  """
  @spec current_date(ctx(), map()) ::
          %{
            date: String.t(),
            format: term(),
            timezone: String.t(),
            day_of_week: String.t(),
            is_weekend: boolean()
          }
          | timezone_error()
  def current_date(_ctx, args) do
    format = Map.get(args, "format", "iso8601")

    with_timezone(args, fn timezone ->
      date = get_date_in_timezone(timezone)

      formatted_date =
        case format do
          "iso8601" -> Date.to_iso8601(date)
          "us" -> Calendar.strftime(date, "%m/%d/%Y")
          "eu" -> Calendar.strftime(date, "%d/%m/%Y")
          "full" -> Calendar.strftime(date, "%A, %B %-d, %Y")
          "short" -> Calendar.strftime(date, "%b %-d, %Y")
          _ -> Date.to_iso8601(date)
        end

      %{
        date: formatted_date,
        format: format,
        timezone: timezone,
        day_of_week: Calendar.strftime(date, "%A"),
        is_weekend: Date.day_of_week(date) in [6, 7]
      }
    end)
  end

  @doc """
  Get the current time in the specified format.

  ## Arguments

  - format: "24h" (default, HH:MM:SS), "12h" (hh:MM:SS AM/PM), "short" (HH:MM)
  - timezone: "Etc/UTC" (default), or its alias "UTC". Any other zone returns an error.
  """
  @spec current_time(ctx(), map()) ::
          %{
            time: String.t(),
            format: term(),
            timezone: String.t(),
            hour: Calendar.hour(),
            minute: Calendar.minute(),
            second: Calendar.second()
          }
          | timezone_error()
  def current_time(_ctx, args) do
    format = Map.get(args, "format", "24h")

    with_timezone(args, fn timezone ->
      time = get_time_in_timezone(timezone)

      formatted_time =
        case format do
          "24h" -> Time.to_iso8601(time)
          "12h" -> Calendar.strftime(time, "%I:%M:%S %p")
          "short" -> Calendar.strftime(time, "%H:%M")
          _ -> Time.to_iso8601(time)
        end

      %{
        time: formatted_time,
        format: format,
        timezone: timezone,
        hour: time.hour,
        minute: time.minute,
        second: time.second
      }
    end)
  end

  @doc """
  Get the current date and time together.

  ## Arguments

  - format: "iso8601" (default), "rfc3339", "unix", "human"
  - timezone: "Etc/UTC" (default), or its alias "UTC". Any other zone returns an error.
  """
  @spec current_datetime(ctx(), map()) ::
          %{
            datetime: String.t(),
            format: term(),
            timezone: String.t(),
            unix_timestamp: integer(),
            date: String.t(),
            time: String.t()
          }
          | timezone_error()
  def current_datetime(_ctx, args) do
    format = Map.get(args, "format", "iso8601")

    with_timezone(args, fn timezone ->
      datetime = get_datetime_in_timezone(timezone)

      formatted =
        case format do
          "iso8601" -> DateTime.to_iso8601(datetime)
          "rfc3339" -> DateTime.to_string(datetime)
          "unix" -> DateTime.to_unix(datetime) |> to_string()
          "human" -> Calendar.strftime(datetime, "%A, %B %-d, %Y at %I:%M %p %Z")
          _ -> DateTime.to_iso8601(datetime)
        end

      %{
        datetime: formatted,
        format: format,
        timezone: timezone,
        unix_timestamp: DateTime.to_unix(datetime),
        date: Date.to_iso8601(DateTime.to_date(datetime)),
        time: Time.to_iso8601(DateTime.to_time(datetime))
      }
    end)
  end

  @doc """
  Calculate the difference between two dates.

  ## Arguments

  - date1: First date in ISO8601 format (YYYY-MM-DD)
  - date2: Second date in ISO8601 format (YYYY-MM-DD)
  - unit: "days" (default), "weeks", "months", "years"
  """
  @spec date_difference(ctx(), map()) ::
          %{
            date1: String.t(),
            date2: String.t(),
            difference: number(),
            unit: term(),
            diff_days: integer(),
            direction: String.t()
          }
          | %{error: String.t()}
  def date_difference(_ctx, args) do
    # Support both date1/date2 and start_date/end_date parameter names
    date1_str = Map.get(args, "date1") || Map.get(args, "start_date")
    date2_str = Map.get(args, "date2") || Map.get(args, "end_date")
    unit = Map.get(args, "unit", "days")

    with {:ok, date1} <- Date.from_iso8601(date1_str),
         {:ok, date2} <- Date.from_iso8601(date2_str) do
      diff_days = Date.diff(date2, date1)

      result =
        case unit do
          "days" -> diff_days
          "weeks" -> Float.round(diff_days / 7, 2)
          # Average month length
          "months" -> Float.round(diff_days / 30.44, 2)
          # Account for leap years
          "years" -> Float.round(diff_days / 365.25, 2)
          _ -> diff_days
        end

      %{
        date1: date1_str,
        date2: date2_str,
        difference: result,
        unit: unit,
        diff_days: diff_days,
        direction: if(diff_days > 0, do: "future", else: "past")
      }
    else
      {:error, reason} ->
        %{error: "Invalid date format: #{inspect(reason)}"}
    end
  end

  @doc """
  Add or subtract days from a date.

  ## Arguments

  - date: Date in ISO8601 format (YYYY-MM-DD), defaults to today
  - days: Number of days to add (positive) or subtract (negative)
  """
  @spec add_days(ctx(), map()) :: %{
          original_date: String.t(),
          days_added: integer(),
          result_date: String.t(),
          result_day_of_week: String.t(),
          is_weekend: boolean()
        }
  def add_days(_ctx, args) do
    date_str = Map.get(args, "date")
    days = Map.get(args, "days", 0)

    base_date =
      if date_str do
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end
      else
        Date.utc_today()
      end

    result_date = Date.add(base_date, days)

    %{
      original_date: Date.to_iso8601(base_date),
      days_added: days,
      result_date: Date.to_iso8601(result_date),
      result_day_of_week: Calendar.strftime(result_date, "%A"),
      is_weekend: Date.day_of_week(result_date) in [6, 7]
    }
  end

  @doc """
  Check if a date is a weekend.

  ## Arguments

  - date: Date in ISO8601 format (YYYY-MM-DD), defaults to today
  """
  @spec is_weekend(ctx(), map()) :: %{
          date: String.t(),
          day_of_week: String.t(),
          day_number: Calendar.day_of_week(),
          is_weekend: boolean(),
          is_weekday: boolean()
        }
  def is_weekend(_ctx, args) do
    date_str = Map.get(args, "date")

    date =
      if date_str do
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end
      else
        Date.utc_today()
      end

    day_of_week = Date.day_of_week(date)
    is_weekend = day_of_week in [6, 7]

    %{
      date: Date.to_iso8601(date),
      day_of_week: Calendar.strftime(date, "%A"),
      day_number: day_of_week,
      is_weekend: is_weekend,
      is_weekday: !is_weekend
    }
  end

  @doc """
  Get the day of the week for a given date.

  ## Arguments

  - date: Date in ISO8601 format (YYYY-MM-DD), defaults to today
  """
  @spec day_of_week(ctx(), map()) :: %{
          date: String.t(),
          day_of_week: String.t(),
          day_abbreviation: String.t(),
          day_number: Calendar.day_of_week(),
          is_weekend: boolean()
        }
  def day_of_week(_ctx, args) do
    date_str = Map.get(args, "date")

    date =
      if date_str do
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end
      else
        Date.utc_today()
      end

    %{
      date: Date.to_iso8601(date),
      day_of_week: Calendar.strftime(date, "%A"),
      day_abbreviation: Calendar.strftime(date, "%a"),
      day_number: Date.day_of_week(date),
      is_weekend: Date.day_of_week(date) in [6, 7]
    }
  end

  @doc """
  Parse a human-readable date string.

  ## Arguments

  - date_string: Date in various formats (ISO8601, MM/DD/YYYY, DD/MM/YYYY, etc.)
  - format: Expected format hint ("iso8601", "us", "eu")
  """
  @spec parse_date(ctx(), map()) ::
          %{original: String.t(), parsed_date: String.t(), day_of_week: String.t(), success: true}
          | %{original: String.t(), error: String.t(), success: false}
  def parse_date(_ctx, args) do
    # Support both "date_string" and "date" parameter names
    date_string = Map.get(args, "date_string") || Map.get(args, "date")
    format_hint = Map.get(args, "format", "iso8601")

    result =
      case format_hint do
        "iso8601" ->
          Date.from_iso8601(date_string)

        "us" ->
          # MM/DD/YYYY
          parse_us_date(date_string)

        "eu" ->
          # DD/MM/YYYY
          parse_eu_date(date_string)

        _ ->
          Date.from_iso8601(date_string)
      end

    case result do
      {:ok, date} ->
        %{
          original: date_string,
          parsed_date: Date.to_iso8601(date),
          day_of_week: Calendar.strftime(date, "%A"),
          success: true
        }

      {:error, reason} ->
        %{
          original: date_string,
          error: inspect(reason),
          success: false
        }
    end
  end

  @doc """
  Get the start and end of the current week.

  ## Arguments

  - timezone: "Etc/UTC" (default), or its alias "UTC". Any other zone returns an error.
  - week_start: Day to consider start of week (1=Monday default, 7=Sunday)
  """
  @spec current_week(ctx(), map()) ::
          %{
            week_start: String.t(),
            week_end: String.t(),
            current_date: String.t(),
            days_in_week: [%{date: String.t(), day_of_week: String.t(), is_weekend: boolean()}]
          }
          | timezone_error()
  def current_week(_ctx, args) do
    # Monday
    week_start = Map.get(args, "week_start", 1)

    with_timezone(args, fn timezone ->
      today = get_date_in_timezone(timezone)
      day_of_week = Date.day_of_week(today)

      # Calculate days to subtract to get to week start
      days_to_start = rem(day_of_week - week_start + 7, 7)
      week_start_date = Date.add(today, -days_to_start)
      week_end_date = Date.add(week_start_date, 6)

      %{
        week_start: Date.to_iso8601(week_start_date),
        week_end: Date.to_iso8601(week_end_date),
        current_date: Date.to_iso8601(today),
        days_in_week: generate_week_days(week_start_date)
      }
    end)
  end

  @doc """
  Get information about the current month.

  ## Arguments

  - timezone: "Etc/UTC" (default), or its alias "UTC". Any other zone returns an error.
  """
  @spec current_month(ctx(), map()) ::
          %{
            month: String.t(),
            month_number: Calendar.month(),
            year: Calendar.year(),
            first_day: String.t(),
            last_day: String.t(),
            days_in_month: pos_integer(),
            current_date: String.t()
          }
          | timezone_error()
  def current_month(_ctx, args) do
    with_timezone(args, fn timezone ->
      today = get_date_in_timezone(timezone)
      first_day = Date.beginning_of_month(today)
      last_day = Date.end_of_month(today)
      days_in_month = Date.diff(last_day, first_day) + 1

      %{
        month: Calendar.strftime(today, "%B"),
        month_number: today.month,
        year: today.year,
        first_day: Date.to_iso8601(first_day),
        last_day: Date.to_iso8601(last_day),
        days_in_month: days_in_month,
        current_date: Date.to_iso8601(today)
      }
    end)
  end

  # Private helper functions

  # Resolve the model-supplied zone once, then hand the vetted value to the
  # body. Returning the error map (rather than raising, or returning an
  # {:error, _} tuple no other function here produces) keeps an unsupported
  # zone in the same shape as the module's other rejections — `parse_date/2`
  # and `date_difference/2` both answer bad input with an `:error` key — so
  # the model reads a correction instead of the tool call blowing up.
  defp with_timezone(args, fun) do
    case resolve_timezone(Map.get(args, "timezone", @utc_zone)) do
      {:ok, timezone} -> fun.(timezone)
      {:error, error} -> error
    end
  end

  defp resolve_timezone(timezone) when timezone in @supported_timezones, do: {:ok, @utc_zone}

  defp resolve_timezone(timezone) do
    {:error,
     %{
       error:
         "Unsupported timezone: #{inspect(timezone)}. Supported: " <>
           Enum.map_join(@supported_timezones, ", ", &inspect/1) <>
           ". This build has no time zone database beyond UTC.",
       timezone: timezone,
       supported_timezones: @supported_timezones
     }}
  end

  defp get_date_in_timezone(timezone) do
    DateTime.now!(timezone)
    |> DateTime.to_date()
  end

  defp get_time_in_timezone(timezone) do
    DateTime.now!(timezone)
    |> DateTime.to_time()
  end

  defp get_datetime_in_timezone(timezone) do
    DateTime.now!(timezone)
  end

  defp parse_us_date(date_string) do
    # MM/DD/YYYY
    case String.split(date_string, "/") do
      [month, day, year] ->
        Date.from_iso8601(
          "#{year}-#{String.pad_leading(month, 2, "0")}-#{String.pad_leading(day, 2, "0")}"
        )

      _ ->
        {:error, :invalid_format}
    end
  end

  defp parse_eu_date(date_string) do
    # DD/MM/YYYY
    case String.split(date_string, "/") do
      [day, month, year] ->
        Date.from_iso8601(
          "#{year}-#{String.pad_leading(month, 2, "0")}-#{String.pad_leading(day, 2, "0")}"
        )

      _ ->
        {:error, :invalid_format}
    end
  end

  defp generate_week_days(start_date) do
    0..6
    |> Enum.map(fn offset ->
      date = Date.add(start_date, offset)

      %{
        date: Date.to_iso8601(date),
        day_of_week: Calendar.strftime(date, "%A"),
        is_weekend: Date.day_of_week(date) in [6, 7]
      }
    end)
  end
end

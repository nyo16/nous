defmodule Nous.Tools.DateTimeToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.DateTimeTools

  # The "current *" functions read the wall clock, so their results are pinned
  # against the dates observed either side of the call. A midnight rollover
  # between the two samples is then a passing run rather than a flake.
  defp with_today_window(fun) do
    before_date = Date.utc_today()
    result = fun.()
    {result, Enum.uniq([before_date, Date.utc_today()])}
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Every "current" tool takes the same model-supplied `timezone`, so the
  # guard is asserted once across all five rather than five times over.
  @clock_tools [
    {:current_date, &Nous.Tools.DateTimeTools.current_date/2},
    {:current_time, &Nous.Tools.DateTimeTools.current_time/2},
    {:current_datetime, &Nous.Tools.DateTimeTools.current_datetime/2},
    {:current_week, &Nous.Tools.DateTimeTools.current_week/2},
    {:current_month, &Nous.Tools.DateTimeTools.current_month/2}
  ]

  describe "timezone handling" do
    test "\"UTC\" is accepted as an alias for \"Etc/UTC\"" do
      # A model produces the bare spelling constantly and it is unambiguous;
      # before the alias it raised ArgumentError out of DateTime.now!/1.
      for {name, tool} <- @clock_tools do
        result = tool.(nil, %{"timezone" => "UTC"})

        refute Map.has_key?(result, :error), "#{name} rejected \"UTC\""
        assert Map.get(result, :timezone, "Etc/UTC") == "Etc/UTC"
      end
    end

    test "an unsupported zone is refused with a correction, not an exception" do
      # The argument is model-supplied, so an unknown zone is expected input.
      # These are the zones this module's own @docs used to suggest.
      for {name, tool} <- @clock_tools,
          zone <- ["America/New_York", "Europe/London", "Mars/Olympus", "", nil, 7] do
        result = tool.(nil, %{"timezone" => zone})

        assert %{error: error, supported_timezones: ["UTC", "Etc/UTC"]} = result,
               "#{name} did not refuse #{inspect(zone)}"

        assert error =~ "Unsupported timezone"
        assert error =~ inspect(zone)
        assert result.timezone == zone
      end
    end

    test "the refusal replaces the result, so no stale date leaks with it" do
      result = DateTimeTools.current_date(nil, %{"timezone" => "America/New_York"})

      refute Map.has_key?(result, :date)
      refute Map.has_key?(result, :day_of_week)
    end

    test "omitting the timezone still defaults to Etc/UTC" do
      for {name, tool} <- @clock_tools do
        result = tool.(nil, %{})
        refute Map.has_key?(result, :error), "#{name} refused the default"
      end
    end
  end

  describe "current_date/2" do
    test "renders the wall-clock date in each supported format" do
      formats = [
        {"iso8601", &Date.to_iso8601/1},
        {"us", &Calendar.strftime(&1, "%m/%d/%Y")},
        {"eu", &Calendar.strftime(&1, "%d/%m/%Y")},
        {"full", &Calendar.strftime(&1, "%A, %B %-d, %Y")},
        {"short", &Calendar.strftime(&1, "%b %-d, %Y")},
        # An unrecognised format from the model must not produce an empty or
        # crashed result; it falls back to ISO.
        {"martian", &Date.to_iso8601/1}
      ]

      for {format, expected} <- formats do
        {result, dates} =
          with_today_window(fn -> DateTimeTools.current_date(nil, %{"format" => format}) end)

        assert result.date in Enum.map(dates, expected),
               "format #{format} rendered #{result.date}"

        assert result.format == format
        assert result.timezone == "Etc/UTC"
      end
    end

    test "the derived weekday fields agree with the date it reports" do
      {result, _dates} = with_today_window(fn -> DateTimeTools.current_date(nil, %{}) end)

      date = Date.from_iso8601!(result.date)
      assert result.day_of_week == Calendar.strftime(date, "%A")
      assert result.is_weekend == Date.day_of_week(date) in [6, 7]
    end
  end

  describe "current_time/2" do
    test "the formatted string agrees with the hour/minute/second it reports" do
      # Both come from a single `Time`, so this is an exact cross-check with no
      # clock race: a format branch reading the wrong component fails it.
      result = DateTimeTools.current_time(nil, %{"format" => "24h"})

      assert String.starts_with?(
               result.time,
               "#{pad(result.hour)}:#{pad(result.minute)}:#{pad(result.second)}"
             )

      assert result.format == "24h"
      assert result.timezone == "Etc/UTC"
    end

    test "short drops the seconds" do
      result = DateTimeTools.current_time(nil, %{"format" => "short"})

      assert result.time == "#{pad(result.hour)}:#{pad(result.minute)}"
    end

    test "12h wraps the hour and carries the correct meridiem" do
      result = DateTimeTools.current_time(nil, %{"format" => "12h"})

      expected_hour = rem(rem(result.hour, 12) + 11, 12) + 1
      meridiem = if result.hour < 12, do: "AM", else: "PM"
      clock = "#{pad(expected_hour)}:#{pad(result.minute)}:#{pad(result.second)}"

      assert result.time == "#{clock} #{meridiem}"
    end

    test "an unknown format falls back to 24h rather than an empty string" do
      result = DateTimeTools.current_time(nil, %{"format" => "sundial"})

      assert String.starts_with?(result.time, "#{pad(result.hour)}:#{pad(result.minute)}")
      assert result.format == "sundial"
    end
  end

  describe "current_datetime/2" do
    test "iso8601 is composed of the date and time fields it also returns" do
      result = DateTimeTools.current_datetime(nil, %{})

      assert result.datetime == "#{result.date}T#{result.time}Z"
      assert result.format == "iso8601"
    end

    test "unix renders the same instant as the unix_timestamp field" do
      result = DateTimeTools.current_datetime(nil, %{"format" => "unix"})

      assert result.datetime == Integer.to_string(result.unix_timestamp)

      assert result.unix_timestamp
             |> DateTime.from_unix!()
             |> DateTime.to_date()
             |> Date.to_iso8601() == result.date
    end

    test "rfc3339 and human render the same instant in a different shape" do
      for format <- ["rfc3339", "human"] do
        result = DateTimeTools.current_datetime(nil, %{"format" => format})

        assert result.datetime =~ Integer.to_string(Date.from_iso8601!(result.date).year)
        assert result.format == format
      end

      human = DateTimeTools.current_datetime(nil, %{"format" => "human"})
      assert human.datetime =~ ~r/\d{1,2}:\d{2} (AM|PM)/
    end

    test "an unknown format falls back to iso8601" do
      result = DateTimeTools.current_datetime(nil, %{"format" => "hourglass"})

      assert result.datetime == "#{result.date}T#{result.time}Z"
    end
  end

  describe "date_difference/2" do
    test "converts the day count into the requested unit" do
      cases = [
        {"days", 30},
        # 30/7, 30/30.44 and 30/365.25, each rounded to two places.
        {"weeks", 4.29},
        {"months", 0.99},
        {"years", 0.08},
        # Unknown units fall back to raw days rather than erroring.
        {"fortnights", 30}
      ]

      for {unit, expected} <- cases do
        result =
          DateTimeTools.date_difference(nil, %{
            "date1" => "2025-01-01",
            "date2" => "2025-01-31",
            "unit" => unit
          })

        assert result.difference == expected, "unit #{unit} gave #{inspect(result.difference)}"
        assert result.diff_days == 30
        assert result.unit == unit
      end
    end

    test "start_date/end_date are accepted as aliases for date1/date2" do
      assert %{diff_days: 30, direction: "future"} =
               DateTimeTools.date_difference(nil, %{
                 "start_date" => "2025-01-01",
                 "end_date" => "2025-01-31"
               })
    end

    test "a second date before the first reads as past" do
      result =
        DateTimeTools.date_difference(nil, %{"date1" => "2025-01-31", "date2" => "2025-01-01"})

      assert result.diff_days == -30
      assert result.direction == "past"
    end

    test "an unparseable date returns an error map instead of a bogus difference" do
      result =
        DateTimeTools.date_difference(nil, %{"date1" => "2025-13-45", "date2" => "2025-01-01"})

      assert %{error: error} = result
      assert error =~ "Invalid date format"
      refute Map.has_key?(result, :diff_days)
    end
  end

  describe "add_days/2" do
    test "crosses month and year boundaries" do
      cases = [
        {"2025-01-31", 1, "2025-02-01", "Saturday", true},
        {"2025-03-01", -1, "2025-02-28", "Friday", false},
        {"2024-02-28", 1, "2024-02-29", "Thursday", false},
        {"2025-12-31", 1, "2026-01-01", "Thursday", false},
        {"2025-06-11", 0, "2025-06-11", "Wednesday", false}
      ]

      for {date, days, expected, weekday, weekend} <- cases do
        result = DateTimeTools.add_days(nil, %{"date" => date, "days" => days})

        assert result.result_date == expected
        assert result.result_day_of_week == weekday
        assert result.is_weekend == weekend
        assert result.original_date == date
        assert result.days_added == days
      end
    end

    test "an unparseable date falls back to today rather than erroring" do
      {result, dates} =
        with_today_window(fn ->
          DateTimeTools.add_days(nil, %{"date" => "yesterday-ish", "days" => 0})
        end)

      assert result.original_date in Enum.map(dates, &Date.to_iso8601/1)
    end

    test "an omitted date defaults to today and an omitted count to zero" do
      {result, dates} = with_today_window(fn -> DateTimeTools.add_days(nil, %{}) end)

      assert result.days_added == 0
      assert result.original_date == result.result_date
      assert result.original_date in Enum.map(dates, &Date.to_iso8601/1)
    end
  end

  describe "is_weekend/2" do
    test "classifies a full week" do
      # 2025-01-06 is a Monday.
      cases = [
        {"2025-01-06", 1, false},
        {"2025-01-07", 2, false},
        {"2025-01-08", 3, false},
        {"2025-01-09", 4, false},
        {"2025-01-10", 5, false},
        {"2025-01-11", 6, true},
        {"2025-01-12", 7, true}
      ]

      for {date, day_number, weekend} <- cases do
        result = DateTimeTools.is_weekend(nil, %{"date" => date})

        assert result.date == date
        assert result.day_number == day_number
        assert result.is_weekend == weekend
        # The two flags are reported separately, so they have to stay opposites.
        assert result.is_weekday == not weekend
      end
    end

    test "an unparseable date falls back to today" do
      {result, dates} =
        with_today_window(fn -> DateTimeTools.is_weekend(nil, %{"date" => "next tuesday"}) end)

      assert result.date in Enum.map(dates, &Date.to_iso8601/1)
    end
  end

  describe "day_of_week/2" do
    test "names, abbreviates and numbers a known week" do
      cases = [
        {"2025-01-06", "Monday", "Mon", 1},
        {"2025-01-09", "Thursday", "Thu", 4},
        {"2025-01-11", "Saturday", "Sat", 6},
        {"2025-01-12", "Sunday", "Sun", 7}
      ]

      for {date, name, abbreviation, number} <- cases do
        result = DateTimeTools.day_of_week(nil, %{"date" => date})

        assert result.day_of_week == name
        assert result.day_abbreviation == abbreviation
        assert result.day_number == number
        assert result.is_weekend == number in [6, 7]
      end
    end
  end

  describe "parse_date/2" do
    test "the same string parses differently under the us and eu hints" do
      # This is the whole point of the format hint, and the one place an
      # LLM-supplied date silently means a different day.
      us = DateTimeTools.parse_date(nil, %{"date_string" => "03/04/2025", "format" => "us"})
      eu = DateTimeTools.parse_date(nil, %{"date_string" => "03/04/2025", "format" => "eu"})

      assert %{parsed_date: "2025-03-04", success: true, day_of_week: "Tuesday"} = us
      assert %{parsed_date: "2025-04-03", success: true, day_of_week: "Thursday"} = eu
    end

    test "single-digit components are zero-padded before parsing" do
      assert %{parsed_date: "2025-03-04", success: true} =
               DateTimeTools.parse_date(nil, %{"date_string" => "3/4/2025", "format" => "us"})

      assert %{parsed_date: "2025-04-03", success: true} =
               DateTimeTools.parse_date(nil, %{"date_string" => "3/4/2025", "format" => "eu"})
    end

    test "iso8601 is the default and the fallback for an unknown hint" do
      for args <- [
            %{"date_string" => "2025-03-04"},
            %{"date_string" => "2025-03-04", "format" => "iso8601"},
            %{"date_string" => "2025-03-04", "format" => "julian"}
          ] do
        assert %{parsed_date: "2025-03-04", success: true} = DateTimeTools.parse_date(nil, args)
      end
    end

    test "\"date\" is accepted as an alias for \"date_string\"" do
      assert %{parsed_date: "2025-03-04", success: true} =
               DateTimeTools.parse_date(nil, %{"date" => "2025-03-04"})
    end

    test "an unparseable string reports failure instead of a wrong date" do
      cases = [
        {%{"date_string" => "not-a-date"}, "invalid_format"},
        {%{"date_string" => "2025-13-45"}, "invalid_date"},
        {%{"date_string" => "03-04-2025", "format" => "us"}, "invalid_format"},
        {%{"date_string" => "03/2025", "format" => "eu"}, "invalid_format"}
      ]

      for {args, reason} <- cases do
        result = DateTimeTools.parse_date(nil, args)

        assert result.success == false, "#{inspect(args)} unexpectedly parsed"
        assert result.error =~ reason
        assert result.original == args["date_string"]
        refute Map.has_key?(result, :parsed_date)
      end
    end
  end

  describe "current_week/2" do
    test "the week starts on the requested day for every possible week_start" do
      for week_start <- 1..7 do
        result = DateTimeTools.current_week(nil, %{"week_start" => week_start})

        start_date = Date.from_iso8601!(result.week_start)
        end_date = Date.from_iso8601!(result.week_end)
        today = Date.from_iso8601!(result.current_date)

        assert Date.day_of_week(start_date) == week_start
        assert Date.diff(end_date, start_date) == 6
        # Today has to fall inside the window the tool just described.
        assert Date.compare(today, start_date) != :lt
        assert Date.compare(today, end_date) != :gt
      end
    end

    test "defaults to a Monday start" do
      result = DateTimeTools.current_week(nil, %{})

      assert Date.day_of_week(Date.from_iso8601!(result.week_start)) == 1
    end

    test "days_in_week enumerates the seven days of the described window" do
      result = DateTimeTools.current_week(nil, %{})
      start_date = Date.from_iso8601!(result.week_start)

      assert length(result.days_in_week) == 7

      for {day, offset} <- Enum.with_index(result.days_in_week) do
        expected = Date.add(start_date, offset)

        assert day.date == Date.to_iso8601(expected)
        assert day.day_of_week == Calendar.strftime(expected, "%A")
        assert day.is_weekend == Date.day_of_week(expected) in [6, 7]
      end

      assert Enum.count(result.days_in_week, & &1.is_weekend) == 2
    end
  end

  describe "current_month/2" do
    test "the month window matches the calendar" do
      result = DateTimeTools.current_month(nil, %{})

      today = Date.from_iso8601!(result.current_date)
      first = Date.from_iso8601!(result.first_day)
      last = Date.from_iso8601!(result.last_day)

      assert first.day == 1
      assert {first.month, first.year} == {today.month, today.year}
      assert {last.month, last.year} == {today.month, today.year}
      # Independent oracle: the stdlib, not the same arithmetic under test.
      assert last.day == Date.days_in_month(today)
      assert result.days_in_month == Date.days_in_month(today)
      assert result.month_number == today.month
      assert result.year == today.year
      assert result.month == Calendar.strftime(today, "%B")
    end
  end
end

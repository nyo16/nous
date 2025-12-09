defmodule TradingDesk.Tools.Trading do
  @moduledoc """
  Mock trading execution tools for trading executor agent.
  """

  @doc """
  Get current account balance and buying power.
  """
  def get_account_balance(_ctx, _args) do
    %{
      cash_balance: 125_000.00,
      buying_power: 250_000.00,
      portfolio_value: 375_000.00,
      total_value: 500_000.00,
      margin_used: 0.0,
      currency: "USD"
    }
  end

  @doc """
  Get all open positions.
  """
  def get_open_positions(_ctx, _args) do
    positions = [
      %{
        symbol: "AAPL",
        quantity: 100,
        entry_price: 170.00,
        current_price: 178.50,
        value: 17_850.00,
        pnl: 850.00,
        pnl_percent: 5.0
      },
      %{
        symbol: "MSFT",
        quantity: 50,
        entry_price: 360.00,
        current_price: 378.90,
        value: 18_945.00,
        pnl: 945.00,
        pnl_percent: 5.25
      },
      %{
        symbol: "GOOGL",
        quantity: 75,
        entry_price: 140.00,
        current_price: 142.30,
        value: 10_672.50,
        pnl: 172.50,
        pnl_percent: 1.64
      }
    ]

    %{
      positions: positions,
      count: length(positions),
      total_value: Enum.reduce(positions, 0, & &1.value + &2),
      total_pnl: Enum.reduce(positions, 0, & &1.pnl + &2)
    }
  end

  @doc """
  Place a trading order.

  ## Parameters
  - symbol: Stock ticker
  - quantity: Number of shares
  - price: Limit price (optional)
  - type: Order type ("market" or "limit")
  - side: "buy" or "sell"
  """
  def place_order(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")
    quantity = Map.get(args, "quantity", 0)
    price = Map.get(args, "price")
    order_type = Map.get(args, "type", "market")
    side = Map.get(args, "side", "buy")

    # Generate mock order ID
    order_id = "ORD-#{:rand.uniform(999_999)}"

    %{
      order_id: order_id,
      symbol: symbol,
      quantity: quantity,
      price: price,
      type: order_type,
      side: side,
      status: "pending",
      timestamp: DateTime.utc_now() |> DateTime.to_string(),
      estimated_value: quantity * (price || 100.0),
      message: "Order #{order_id} placed successfully"
    }
  end

  @doc """
  Get pending orders.
  """
  def get_pending_orders(_ctx, _args) do
    %{
      orders: [
        %{
          order_id: "ORD-123456",
          symbol: "NVDA",
          quantity: 25,
          price: 490.00,
          type: "limit",
          side: "buy",
          status: "pending"
        }
      ],
      count: 1
    }
  end

  @doc """
  Cancel an order.

  ## Parameters
  - order_id: Order ID to cancel
  """
  def cancel_order(_ctx, args) do
    order_id = Map.get(args, "order_id", "UNKNOWN")

    %{
      order_id: order_id,
      status: "cancelled",
      timestamp: DateTime.utc_now() |> DateTime.to_string(),
      message: "Order #{order_id} cancelled successfully"
    }
  end
end

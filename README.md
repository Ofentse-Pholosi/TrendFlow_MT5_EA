# TrendFlow EA — MetaTrader 5 Expert Advisor

> **Version:** 4.0 · **File:** `TrendFlow_EA_v1.00.mq5` · **Platform:** MetaTrader 5

---

## Table of Contents

1. [Overview](#overview)
2. [Strategy Architecture](#strategy-architecture)
   - [Engine 1 — EMA-200 Crossover](#engine-1--ema-200-crossover)
   - [Engine 2 — Envelopes Band-Touch Reversal](#engine-2--envelopes-band-touch-reversal)
   - [Engine 3 — MA60 Fast Entry](#engine-3--ma60-fast-entry)
3. [Entry Filters](#entry-filters)
   - [ADX Trend Strength Filter](#adx-trend-strength-filter)
   - [Candle Body Filter](#candle-body-filter)
   - [RSI Confluence Filter](#rsi-confluence-filter)
   - [Retry Logic](#retry-logic)
4. [Position Management](#position-management)
   - [Scale-In](#scale-in)
   - [Trailing Stop](#trailing-stop)
   - [Break-Even](#break-even)
   - [SL-Flip Recovery](#sl-flip-recovery)
   - [Profit Target](#profit-target)
5. [Goal Tracker](#goal-tracker)
6. [TP / SL Modes](#tp--sl-modes)
7. [Lot Sizing](#lot-sizing)
8. [Input Parameter Reference](#input-parameter-reference)
9. [Trade Entry Logger](#trade-entry-logger)
10. [Live Dashboard](#live-dashboard)
11. [Installation](#installation)
12. [Recommended Workflows](#recommended-workflows)
13. [Notes & Caveats](#notes--caveats)

---

## Overview

**TrendFlow EA** is a multi-engine, trend-following Expert Advisor built for MetaTrader 5. It combines three independent entry strategies under a single unified risk and position-management framework:

| Engine | Signal Type | Primary Indicator |
|--------|-------------|-------------------|
| EMA-200 Crossover | Trend-following | 200-period EMA |
| Envelopes Reversal | Counter-trend / Mean reversion | Envelopes (EMA-200 ± deviation %) |
| MA60 Fast Entry | Momentum pullback | 60-period LWMA (shifted) |

All three engines share the same lot-sizing, TP/SL, trailing stop, break-even, scale-in, and profit-target logic, and are individually switchable via their respective `_On` input.

---

## Strategy Architecture

### Engine 1 — EMA-200 Crossover

The primary entry engine. A trade is triggered when the **last closed bar's close crosses the 200-period EMA**.

**Buy signal:** Previous close was below EMA; current close is above EMA.  
**Sell signal:** Previous close was above EMA; current close is below EMA.

Both the ADX filter and the candle body filter are applied before entry. If ADX is insufficient at crossover time, the signal can be held in a **pending/retry** state (see [Retry Logic](#retry-logic)).

The EMA-200 also acts as a **directional context gate** for the MA60 engine — buys are only allowed above EMA-200, sells only below.

---

### Engine 2 — Envelopes Band-Touch Reversal

A **counter-trend / mean-reversion** entry triggered when the wick of the last closed bar touches an Envelopes band, **and** ADX is simultaneously very high (default >= 45).

| Condition | Direction |
|-----------|-----------|
| Bar low <= lower band | BUY reversal |
| Bar high >= upper band | SELL reversal |

**Rationale:** A very high ADX reading indicates that price has trended hard enough to overextend and chase the bands — this is the exhaustion point where mean-reversion is most likely to fire.

> **Important:** Reversal entries **always use static SL/TP** (`SL_Pts` / `TP_Pts`) regardless of the global `TPSL_Mode` setting. Counter-trend fades require fixed, predictable stops; ATR-based stops can collapse in fast-trending markets and cause premature SL hits.

A **cooldown** (`Rev_Cooldown`) prevents repeated firing on the same condition within consecutive bars.

The dashboard's **Reversal** row also displays a *narrative* — a scan of the last `Env_LookBack` bars — that tells you whether bullish or bearish band touches have recently occurred, independently of whether an entry was triggered.

---

### Engine 3 — MA60 Fast Entry

A momentum-based entry that fires when **all three conditions align on the same bar**:

1. **Price crosses the 60-period LWMA** (shifted 5 bars) — confirms momentum direction.
2. **RSI crosses a threshold** — RSI crosses above `MA60_RSI_Buy` (default 30) for buys, or below `MA60_RSI_Sell` (default 70) for sells — confirms momentum is turning.
3. **ADX >= `MA60_ADX_Min`** (default 30) — confirms there is sufficient trend strength.
4. **EMA-200 context** — buys only when price is above EMA-200; sells only when below.

This engine has **no retry logic** — all three conditions must fire simultaneously. It uses the same `CalcSLTP`, `CalcLot`, `MaxEntries`, and `TradeDir` settings as all other engines.

---

## Entry Filters

### ADX Trend Strength Filter

Controlled by `ADX_On`, `ADX_Period`, and `ADX_Min`.

Two variants are used internally:

- **`adxOk`** — single bar confirmation (`ADX[1] >= ADX_Min`). Used for the **first entry** in a direction.
- **`adxSustained`** — two consecutive bars above the minimum (`ADX[1] >= ADX_Min AND ADX[2] >= ADX_Min`). Required before **adding concurrent positions** (prevents entries on brief ADX spikes).

Scale-in additions also require `adxSustained`.

---

### Candle Body Filter

Controlled by `Body_On` and `Body_ATR`.

The signal bar (last closed bar) must:
1. **Close in the trade direction** — bullish close for buy, bearish close for sell.
2. **Have a body size >= `Body_ATR` x ATR(14)** — ensures the candle has meaningful directional conviction.

*Example:* `Body_ATR = 0.25` on H1 EURUSD with an ~80-pip ATR requires at least a ~20-pip body.

> The body filter is applied at **crossover time only** in Retry Mode. During retry attempts the check is intentionally skipped — the body already passed when the signal was first detected.

---

### RSI Confluence Filter

Two independent RSI toggles exist:

| Setting | Applies to | Logic |
|---------|-----------|-------|
| `RSI_Cross_On` | EMA crossover & retry entries | RSI[1] > 50 required for BUY; RSI[1] < 50 required for SELL |
| `RSI_Rev_On` | Envelopes reversal entries | RSI must return from an extreme zone (OS->return for buy; OB->return for sell) |

**Reversal RSI logic:**
- **BUY:** `RSI[2] <= RSI_OS_Zone` AND `RSI[1] > RSI_OS_Return` — momentum turning up from oversold.
- **SELL:** `RSI[2] >= RSI_OB_Zone` AND `RSI[1] < RSI_OB_Return` — momentum turning down from overbought.

---

### Retry Logic

When `Retry_On = true`, a crossover signal that **fails the ADX check** is not immediately discarded. Instead:

1. The signal is held **pending** (`pendingBuy` or `pendingSell`).
2. A **delay timer** starts (`Retry_DelayMinutes`). No retry attempts are made during the delay.
3. After the delay, the EA retries **every new bar** until one of the following:
   - **(a) ADX qualifies + all filters pass** — entry is placed, signal cleared.
   - **(b) Two consecutive closes on the wrong side of EMA** — signal cancelled.
   - **(c) `Retry_MaxBars` bars have elapsed after the delay** — signal expired.

Only one pending signal is held at a time; a new crossover in the opposite direction cancels the existing pending signal.

The dashboard's **Signal** row shows the pending state with a countdown (`AWAIT BUY x 3m` / `AWAIT BUY x 2/10b`).

---

## Position Management

### Scale-In

*Toggle:* `SI_On` | *Parameters:* `SI_MaxCap`, `SI_Step`

Automatically adds positions in the same direction when floating profit reaches `SI_Step` points beyond the last entry. Maximum `SI_MaxCap` additions are allowed per direction. `adxSustained` is required before each scale-in.

Scale-in counters reset automatically when all positions of that type are closed.

---

### Trailing Stop

*Toggle:* `Trail_On` | *Parameters:* `Trail_Trigger`, `Trail_Step`

Activates once a position's floating profit reaches `Trail_Trigger` points. After activation, the stop-loss is moved to exactly `Trail_Step` points behind the current price on every tick — moving only in the favourable direction (never in reverse).

> **Tip:** Set `BE_Trigger < Trail_Trigger` so break-even fires first, then the trailing stop takes over.

---

### Break-Even

*Toggle:* `BE_On` | *Parameters:* `BE_Trigger`, `BE_Offset`

Once a position's floating profit reaches `BE_Trigger` points, the SL is moved to `entry price + BE_Offset points` (buy) or `entry price - BE_Offset points` (sell). This fires **once per position** and locks in a small guaranteed profit regardless of subsequent price movement.

*Example:* Entry at 1.10000, `BE_Offset = 5` -> SL moved to 1.10005 (buy) or 1.09995 (sell).

---

### SL-Flip Recovery

*Toggle:* `SLFlip_On` | *Parameters:* `SLFlip_ADX_Min`, `SLFlip_Delay`

When an EA position is closed by its stop-loss **and** ADX at that moment is >= `SLFlip_ADX_Min`, the EA arms a **flip entry** in the opposite direction after `SLFlip_Delay` bars.

**Rationale:** A high ADX at the point of a SL hit means the move was real momentum — being stopped out likely signals a retracement before continuation. The flip captures that continuation.

- `TradeDir` is **ignored** for flip entries — they always take the counter side.
- Normal `CalcLot` and `CalcSLTP` apply.
- Only one flip can be armed at a time; stacking is prevented.
- The dashboard's SETTINGS footer shows `FLIP ARMED: BUY (N bars)` when active.

---

### Profit Target

*Toggle:* `PT_On` | *Parameter:* `PT_Amt`

Closes **all EA positions on the current symbol** when their combined floating P&L (profit + swap + commission) reaches a **fixed dollar amount** (`PT_Amt`). Positions on other symbols are unaffected.

> **Changed from v3:** Previously used `PT_Pct` (a percentage of account balance). The new `PT_Amt` is an absolute dollar figure, making the trigger predictable regardless of account size changes.

---

## Goal Tracker

*Toggle:* `Goal_On` | *Parameters:* `Goal_Schedule`, `Goal_Monthly`, `Goal_LotScale`

The Goal Tracker is a **progressive risk-management system** that automatically reduces lot size once a daily profit target has been met, protecting gains for the rest of the day.

### How It Works

1. **Monthly target is set** via `Goal_Monthly` (e.g. $500).
2. **Daily target is derived dynamically** each tick:
   ```
   Daily target = (Goal_Monthly - month PnL so far) / trading days remaining this month
   ```
   This means the daily target automatically **catches up** if earlier days were below target, and **relaxes** if the month is ahead of pace.
3. **Weekly target** displayed on dashboard = `Daily target × days per week` (5 or 7 depending on schedule).
4. Once `Today's P&L (closed + floating) >= daily target`, all **new lots are multiplied by `Goal_LotScale`** (e.g. 0.5 = half size). Existing open positions are not affected.
5. On **weekends** (Saturday/Sunday), when `Goal_Schedule = Weekdays`, the EA's bar-open gate is skipped entirely — no new entries are placed.

### P&L Calculation

| Component | Included |
|-----------|----------|
| Closed deals (this symbol + Magic) | Yes |
| Open floating P&L (this symbol + Magic) | Yes |
| Swap & commission | Yes |
| Other symbols / other EAs | No |

### Dashboard — GOAL TRACKER section

When `Goal_On = true`, the dashboard shows four live rows between ACCOUNT and SETTINGS:

| Row | Content | Color |
|-----|---------|-------|
| Monthly | Target vs made so far this month | Green ≥ target · Yellow ≥ 50% · Grey below |
| This Week | Weekly target + remaining monthly amount | Grey |
| Daily | Today's per-day target + trading days left | Grey |
| Today | Today's P&L vs daily target | Green = hit · Yellow ≥ 50% · Red < 50% |

When `Goal_On = false`, the section shows `DISABLED`.

---

## TP / SL Modes

Controlled by `TPSL_Mode`:

| Mode | SL Distance | TP Distance |
|------|------------|------------|
| **Static** (`TPSL_STATIC`) | `SL_Pts` points from entry | `TP_Pts` points from entry |
| **Dynamic** (`TPSL_DYNAMIC`) | 1 x ATR(14) from entry | `RR_Ratio` x ATR(14) from entry |

> **Note:** Envelopes reversal entries **always use Static mode** regardless of this setting.

---

## Lot Sizing

Controlled by `LotMode`:

| Mode | Calculation |
|------|------------|
| **Fixed** (`LOT_FIXED`) | Uses `FixedLot` directly |
| **Equity %** (`LOT_PERCENT`) | `risk_amount = equity x EquityPct / 100`; lot is sized so that `SL_Pts` points of adverse movement costs exactly `risk_amount` |

The result is always normalized to the broker's `VOLUME_MIN`, `VOLUME_MAX`, and `VOLUME_STEP` constraints.

**Goal Tracker lot scaling** is applied as a final post-processing step: if `Goal_On = true` and today's P&L has already met the daily target, the computed lot is further multiplied by `Goal_LotScale` (then re-normalized to `lotStep` and `minLot`). This is a one-way reduction — it never increases lot size.

---

## Input Parameter Reference

### Trend & Entry

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EMA_Period` | 200 | EMA period — used as both trend filter and crossover trigger |
| `TradeDir` | Both | Restrict trading to Buy Only, Sell Only, or Both directions |

### Retry Logic

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Retry_On` | true | Enable ADX retry / pending signal system |
| `Retry_MaxBars` | 10 | Maximum retry bars after the delay period (0 = unlimited) |
| `Retry_DelayMinutes` | 15 | Minutes to wait before beginning retry attempts |

### Candle Body Filter

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Body_On` | true | Enable candle body filter |
| `Body_ATR` | 0.25 | Minimum body size as a fraction of ATR(14) |

### ADX Trend Strength

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ADX_On` | true | Enable ADX filter |
| `ADX_Period` | 14 | ADX period |
| `ADX_Min` | 25.0 | Minimum ADX value to allow crossover/retry entries |

### Lot Size

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LotMode` | Fixed | Fixed lot or equity-percentage sizing |
| `FixedLot` | 0.10 | Lot size when using Fixed mode |
| `EquityPct` | 1.0 | Risk percentage of equity when using % mode |

### Order Management

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MaxEntries` | 3 | Maximum simultaneous open positions per direction |

### Scale-In

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SI_On` | false | Enable scale-in |
| `SI_MaxCap` | 3 | Maximum number of scale-in additions per direction |
| `SI_Step` | 50 | Points of profit required to trigger each scale-in |

### TP / SL

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TPSL_Mode` | Static | Static (fixed points) or Dynamic (ATR-based) |
| `RR_Ratio` | 2.0 | Risk:Reward ratio for Dynamic mode |
| `SL_Pts` | 200 | Stop-loss distance in points (Static mode) |
| `TP_Pts` | 400 | Take-profit distance in points (Static mode) |

### Trailing Stop

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Trail_On` | false | Enable trailing stop |
| `Trail_Trigger` | 100 | Points of profit required to activate trailing |
| `Trail_Step` | 50 | Distance the trail keeps behind current price (points) |

### Break-Even

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BE_On` | false | Enable break-even |
| `BE_Trigger` | 50 | Points of profit required to activate break-even |
| `BE_Offset` | 5 | Points above entry to park the SL after break-even fires |

### SL-Flip

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SLFlip_On` | false | Enable SL-Flip recovery |
| `SLFlip_ADX_Min` | 40.0 | Minimum ADX at SL hit to arm the flip |
| `SLFlip_Delay` | 5 | Bars to wait before placing the flip entry |

### Profit Target

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PT_On` | false | Enable profit target |
| `PT_Amt` | 100.0 | Close all symbol positions when floating P&L reaches this fixed $ amount |

### Goal Tracker

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Goal_On` | false | Enable Goal Tracker |
| `Goal_Schedule` | Weekdays | Trading days used for day-count calculations: `GOAL_7DAYS` or `GOAL_WEEKDAYS` (Mon–Fri) |
| `Goal_Monthly` | 500.0 | Monthly profit target in account currency ($) |
| `Goal_LotScale` | 0.50 | Lot multiplier applied once the daily target is met (e.g. 0.5 = halve lot size) |

### Envelopes (Reversal Narrative)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Env_On` | true | Enable Envelopes indicator and reversal display |
| `Env_Period` | 200 | Envelopes period (matches EMA to share the same midline) |
| `Env_Deviation` | 0.3 | Band deviation as a percentage of the midline price |
| `Env_LookBack` | 10 | Bars to scan for the reversal narrative display only |
| `Env_Entry_On` | true | Enable actual entry signals on band touches |
| `Env_ADX_Min` | 45.0 | Minimum ADX for reversal entries (higher than `ADX_Min`) |
| `Rev_Cooldown` | 5 | Minimum bars between consecutive reversal entries |

### RSI

| Parameter | Default | Description |
|-----------|---------|-------------|
| `RSI_Rev_On` | false | RSI confluence gate for reversal entries |
| `RSI_Cross_On` | false | RSI confluence gate for crossover / retry entries |
| `RSI_Period` | 20 | RSI calculation period |
| `RSI_OB_Zone` | 80.0 | Overbought extreme zone (arms sell reversal) |
| `RSI_OB_Return` | 70.0 | RSI must cross back below this to confirm sell reversal |
| `RSI_OS_Zone` | 20.0 | Oversold extreme zone (arms buy reversal) |
| `RSI_OS_Return` | 30.0 | RSI must cross back above this to confirm buy reversal |

### MA60 Fast Entry

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MA60_On` | false | Enable MA60 fast entry engine |
| `MA60_Period` | 60 | LWMA period |
| `MA60_Shift` | 5 | LWMA bar shift (displaces the MA forward on the chart) |
| `MA60_ADX_Min` | 30.0 | Minimum ADX for MA60 entries |
| `MA60_RSI_Buy` | 30.0 | RSI must cross above this level for a buy signal |
| `MA60_RSI_Sell` | 70.0 | RSI must cross below this level for a sell signal |

### EA Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Magic` | 20240101 | Magic number — uniquely identifies this EA's positions |
| `EA_Cmt` | "TrendFlow" | Order comment prefix (suffixed with `_REV`, `_FLIP`, `_SI`, `_MA60` as applicable) |

---

## Trade Entry Logger

Every time TrendFlow opens a trade, it appends a row to a CSV file at:

```
<MT5 Data Folder>\MQL5\Files\TrendFlow_<SYMBOL>_trades.csv
```

The file is created automatically on the first trade. Column headers are written only once (when the file is empty). You can open this file in Excel or import it into any data analysis tool.

**Logged columns:**

| Column | Description |
|--------|-------------|
| Time | Server timestamp of the entry |
| Symbol | Instrument |
| Direction | BUY / SELL |
| Strategy | CROSSOVER, INSTANT, RETRY, REVERSAL, FLIP, SCALE_IN, MA60 |
| Price, SL, TP | Entry, stop-loss, and take-profit prices |
| Lot | Position size |
| ADX, RSI, EMA200, ATR | Indicator snapshots at entry |
| EnvUpper, EnvLower | Envelope band values at entry |
| TPSL_Mode, TradeDir, ADX_Min | Key settings in effect |
| Retry_On, Body_On, MaxEntries | Entry filter settings |
| Env_Entry_On, Env_ADX_Min, Rev_Cooldown | Reversal engine settings |
| RSI_Rev_On, RSI_Cross_On, RSI_Period | RSI filter settings |
| SLFlip_On, SLFlip_ADX_Min, SLFlip_Delay | SL-Flip settings |
| Trail_On, BE_On, PT_On, SI_On, LotMode | Position management settings |

A matching `[TF-ENTRY]` line is also printed to the MT5 **Experts** log tab on every entry, searchable with Ctrl+F.

---

## Live Dashboard

A dark-themed dashboard renders in the top-left corner of the chart and updates every tick.

```
+----------------------------------+
|  TRENDFLOW EA               v4.0 |
|  EURUSD . H1          Magic ...  |
+----------------------------------+
|  MARKET STATUS                   |
|   Trend      BULLISH  ^          |
|   ADX        28.3  TRENDING  v   |
|   Signal     BUY  ^              |
|   Reversal   BULL REVERSAL ^     |
|   EMA 200    1.08342             |
|   RSI(20)    54.7  NEUTRAL       |
+----------------------------------+
|  POSITIONS                       |
|   Open Trades  1 / 3             |
|   Buys / Sells 1 / 0             |
|   Scale-In     OFF               |
+----------------------------------+
|  ACCOUNT                         |
|   Balance   USD 10 000.00        |
|   Equity    USD 10 043.20        |
|   Float P&L +43.20 USD           |
+----------------------------------+
|  GOAL TRACKER                    |
|   Monthly   Tgt $500  Made +$143 |
|   This Week Wk $100  Left $357   |
|   Daily     Day $100  3 days (5d)|
|   Today     +$43.20 / $100  ◈    |
+----------------------------------+
|  SETTINGS                        |
|   Dir: BOTH  Lot: 0.10 FX  ...   |
|   Tr: OFF  BE: OFF  PT: OFF      |
+----------------------------------+
```

**Signal row color coding:**
- Green — Active BUY signal
- Red — Active SELL signal
- Yellow — Pending / awaiting retry (`AWAIT BUY`)
- Teal — Reversal signal (`REV BUY`)
- Grey — No signal

**ADX row color coding:**
- Green — ADX >= `ADX_Min` (TRENDING)
- Yellow — ADX < `ADX_Min` (WEAK)

**Goal Tracker — Today row color coding:**
- Green — Daily target reached (`TARGET HIT` / `GOAL MET`)
- Yellow — 50–99% of daily target reached
- Red — Below 50% of daily target

When `Goal_On = false` the GOAL TRACKER section shows `DISABLED`.

When an SL-Flip is armed, a `FLIP ARMED: BUY (N bars)` alert appears in the SETTINGS footer in yellow.

---

## Installation

1. **Copy the compiled file** `TrendFlow_EA_v1.00.ex5` to your MT5 data folder:
   ```
   <MT5 Data Folder>\MQL5\Experts\
   ```
   Alternatively, copy `TrendFlow_EA_v1.00.mq5` into MetaEditor and compile it with `F7`.

2. **Refresh the Navigator panel** in MT5 (right-click -> Refresh) or restart MT5.

3. **Drag and drop** the EA onto any chart. The EA will attach to that symbol and timeframe.

4. In the EA input dialog:
   - Set your **Magic Number** (unique per chart/symbol if running on multiple instruments simultaneously).
   - Configure your desired entry engines, filters, and risk settings.
   - Enable **"Allow Algorithmic Trading"** in the EA properties.

5. Ensure **AutoTrading is enabled** in the MT5 toolbar.

> **Tip:** Run on a **Demo account** first to validate behaviour on your broker's execution environment before going live.

---

## Recommended Workflows

### Conservative Trend-Following (defaults)
- `Retry_On = true`, `ADX_Min = 25`, `Body_On = true`
- `TPSL_Mode = Static`, `SL_Pts = 200`, `TP_Pts = 400` (2:1 R:R)
- `BE_On = true`, `BE_Trigger = 50`, `BE_Offset = 5`
- `Trail_On = false`, `SI_On = false`

### ATR-Based Dynamic Stops
- `TPSL_Mode = Dynamic`, `RR_Ratio = 2.0`
- `SL_Pts`/`TP_Pts` remain as fallback values only (reversal engine always uses them).

### Multi-Engine Setup
- Enable all three engines with their respective `_On` flags.
- Use `MaxEntries = 1` to avoid position stacking across engines for cleaner risk.
- Set a unique `Magic` number per chart when running on multiple symbols.

### Aggressive Scale-In
- `SI_On = true`, `SI_MaxCap = 3`, `SI_Step = 50`
- `Trail_On = true`, `Trail_Trigger = 100`, `Trail_Step = 50`
- Note: scale-in multiplies both profit potential **and** drawdown risk.

### Goal-Protected Trading
- `Goal_On = true`, `Goal_Monthly = 500.0`, `Goal_Schedule = Weekdays`
- `Goal_LotScale = 0.5` — halves lot size once the daily target is reached
- Pair with `PT_On = true`, `PT_Amt = 50.0` for an intraday hard stop after hitting a fixed-dollar profit
- The daily target recalculates automatically, so underperforming days will set a higher target the next day to stay on pace for the monthly goal

---

## Notes & Caveats

- **Slippage:** The EA uses `ORDER_FILLING_IOC` with 10-point deviation. Adjust in the source for different broker conditions if required.
- **Multiple Symbols:** Run one EA instance per symbol. Use a unique `Magic` number for each instance to prevent cross-symbol position interference.
- **Reversal entries are counter-trend** and carry higher inherent risk. Intended for experienced users comfortable with mean-reversion strategies.
- **SL-Flip** is an aggressive recovery mechanism. Use only with thoroughly backtested parameters (`SLFlip_ADX_Min >= 40` recommended).
- **Backtesting:** All features are compatible with the MT5 Strategy Tester. Use tick-by-tick data for accurate trailing stop and break-even simulation.
- **CSV Logger:** The log file grows unboundedly. Periodically archive or delete old CSV files from `MQL5\Files\` to manage disk space.
- **Dashboard objects** are cleaned up automatically when the EA is removed or the terminal closes. If objects persist after a crash, use MT5's *Delete All* chart objects function.

---

*TrendFlow EA is provided for educational and personal use. Past performance is not indicative of future results. Always test thoroughly before deploying with real capital.*

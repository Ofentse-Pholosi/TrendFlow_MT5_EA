//+------------------------------------------------------------------+
//|                                            TrendFlow_EA.mq5      |
//|                                       TrendFlow EA  –  v4.0      |
//|  Strategy  : 200 EMA crossover trigger  +  ADX  +  Body filter   |
//|  Features  : Envelopes reversal narrative | Scale-In             |
//|              Dynamic/Static TP/SL | Trail Stop | Profit Target   |
//|              Retry logic | Break-Even | Live Dashboard            |
//+------------------------------------------------------------------+
#property copyright   "TrendFlow EA v4.0"
#property version     "4.0"
#property strict
#property description "Trend-following EA: 200 EMA crossover + ADX + Envelopes"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//====================================================================
//  ENUMERATIONS
//====================================================================
enum ENUM_TRADE_DIR
{
   DIR_BUY_ONLY  = 0,  // Buy Only  (aligned with bullish trend)
   DIR_SELL_ONLY = 1,  // Sell Only (aligned with bearish trend)
   DIR_BOTH      = 2   // Both      (disregards trend direction)
};

enum ENUM_LOT_MODE
{
   LOT_FIXED   = 0,    // Fixed Lot Size
   LOT_PERCENT = 1     // % of Account Equity
};

enum ENUM_TPSL_MODE
{
   TPSL_STATIC  = 0,   // Static  – fixed points from entry
   TPSL_DYNAMIC = 1    // Dynamic – ATR-based with R:R ratio
};

//====================================================================
//  INPUTS
//====================================================================

// ── TREND & ENTRY ─────────────────────────────────────────────────
input group             "── TREND & ENTRY ─────────────────────────────────"
input int               EMA_Period      = 200;          // EMA Period (Trend & Entry Trigger)
input ENUM_TRADE_DIR    TradeDir        = DIR_BOTH;     // Trade Direction
// Entry: price crosses 200 EMA on a confirmed candle (see Body Filter below)

// ── RETRY LOGIC ───────────────────────────────────────────────────
input group             "── RETRY LOGIC ───────────────────────────────────"
input bool              Retry_On           = true;      // Enable ADX Retry
input int               Retry_MaxBars      = 10;        // Max bars to retry after delay (0 = unlimited)
input int               Retry_DelayMinutes = 15;        // Minutes to wait before first retry attempt
// After a crossover, if ADX is too weak the signal stays pending.
// The EA waits Retry_DelayMinutes, then retries each new bar until:
//   (a) ADX qualifies + body confirms → enter, (b) price crosses back through EMA → cancel,
//   (c) Retry_MaxBars bars have passed after the delay → expire.

// ── CANDLE BODY FILTER ────────────────────────────────────────────
input group             "── CANDLE BODY FILTER ────────────────────────────"
input bool              Body_On         = true;         // Enable Candle Body Filter
input double            Body_ATR        = 0.25;         // Min body size as fraction of ATR(14)
// Signal candle must: (1) close in trade direction, (2) have body >= Body_ATR * ATR
// Example: Body_ATR=0.25 on H1 EURUSD ~80pip ATR requires at least a ~20pip body

// ── ADX TREND STRENGTH ────────────────────────────────────────────
input group             "── ADX TREND STRENGTH ────────────────────────────"
input bool              ADX_On          = true;         // Enable ADX Filter
input int               ADX_Period      = 14;           // ADX Period
input double            ADX_Min         = 25.0;         // Minimum ADX to allow entry

// ── LOT SIZE ──────────────────────────────────────────────────────
input group             "── LOT SIZE ──────────────────────────────────────"
input ENUM_LOT_MODE     LotMode         = LOT_FIXED;    // Lot Calculation Mode
input double            FixedLot        = 0.10;         // Fixed Lot Size
input double            EquityPct       = 1.0;          // Risk % of Equity per Trade

// ── ORDER MANAGEMENT ──────────────────────────────────────────────
input group             "── ORDER MANAGEMENT ──────────────────────────────"
input int               MaxEntries      = 3;            // Max Simultaneous Entries (per direction)

// ── SCALE-IN ──────────────────────────────────────────────────────
input group             "── SCALE-IN ──────────────────────────────────────"
input bool              SI_On           = false;        // Enable Scale-In
input int               SI_MaxCap       = 3;            // Max Scale-In Additions (per direction)
input int               SI_Step         = 50;           // Points of Profit to Trigger Each Scale-In

// ── TP / SL ───────────────────────────────────────────────────────
input group             "── TP / SL ───────────────────────────────────────"
input ENUM_TPSL_MODE    TPSL_Mode       = TPSL_STATIC;  // TP/SL Mode
input double            RR_Ratio        = 2.0;          // Risk:Reward Ratio (Dynamic mode)
input int               SL_Pts          = 200;          // SL Distance in Points (Static mode)
input int               TP_Pts          = 400;          // TP Distance in Points (Static mode)
// Dynamic mode: SL = 1×ATR(14), TP = RR_Ratio×ATR(14) from entry

// ── TRAILING STOP ─────────────────────────────────────────────────
input group             "── TRAILING STOP ─────────────────────────────────"
input bool              Trail_On        = false;        // Enable Trailing Stop
input int               Trail_Trigger   = 100;          // Activation Threshold (points of profit)
input int               Trail_Step      = 50;           // Trail Distance Behind Price (points)

// ── BREAK-EVEN ────────────────────────────────────────────────────
input group             "── BREAK-EVEN ────────────────────────────────────"
input bool              BE_On           = false;        // Enable Break-Even
input int               BE_Trigger      = 50;           // Points of profit to activate break-even
input int               BE_Offset       = 5;            // Points above entry to park the SL (locks in small profit)
// Example: entry=1.10000, BE_Offset=5 → SL moves to 1.10005 (buy) / 1.09995 (sell)
// Tip: set BE_Trigger < Trail_Trigger so BE fires first, trail takes over after

// ── SL FLIP ───────────────────────────────────────────────────────
input group             "── SL FLIP ────────────────────────────────────────"
input bool              SLFlip_On       = false;       // Enable SL-Flip Recovery
input double            SLFlip_ADX_Min  = 40.0;        // Min ADX at SL hit to arm the flip
input int               SLFlip_Delay    = 5;           // Bars to wait before firing the flip
// Logic: when any EA position is closed by SL AND ADX >= SLFlip_ADX_Min at that
// moment, the EA waits SLFlip_Delay bars then enters the OPPOSITE direction.
// Rationale: high ADX means strong momentum — being stopped out suggests the
// move was real; flipping captures the continuation after the retracement.
// TradeDir is IGNORED for flips (flip always enters the counter side).
// CalcLot and CalcSLTP (TPSL_Mode) apply as normal. One flip per SL hit.

// ── PROFIT TARGET ─────────────────────────────────────────────────
input group             "── PROFIT TARGET ─────────────────────────────────"
input bool              PT_On           = false;        // Enable Profit Target
input double            PT_Amt          = 100.0;        // Target: fixed $ amount (floating P&L)
// Closes THIS symbol's EA positions when their combined floating P&L >= PT_Amt ($)

// ── ENVELOPES (REVERSAL NARRATIVE) ───────────────────────────────
input group             "── ENVELOPES (REVERSAL NARRATIVE) ────────────────"
input bool              Env_On          = true;         // Enable Envelopes Indicator
input int               Env_Period      = 200;          // Envelopes Period (matches EMA)
input double            Env_Deviation   = 0.3;          // Deviation % (upper/lower band distance)
input int               Env_LookBack    = 10;           // Bars to scan for reversal narrative display
input bool              Env_Entry_On    = true;         // Enable Band-Touch Reversal Entries
input double            Env_ADX_Min     = 45.0;         // ADX threshold for reversal entries
input int               Rev_Cooldown    = 5;            // Bars to wait between reversal entries (anti-overtrading)
// Compound trigger — BOTH conditions must pass on the same bar:
//   (1) Wick touch : bar HIGH >= upper band (sell) | bar LOW <= lower band (buy)
//   (2) ADX >= Env_ADX_Min : steep trend confirms an imbalance has built up
// Rationale: a high ADX (45+) means price has trended hard enough to overextend
// and chase the bands — exactly the exhaustion point where mean-reversion fires.
// SL/TP always use SL_Pts / TP_Pts (static) regardless of TPSL_Mode — counter-trend
// fades need predictable fixed stops, not ATR-scaled ones in fast-trending markets.
// TradeDir, MaxEntries, concurrent ADX gate, Break-Even, Trail Stop all apply.

// ── RSI ───────────────────────────────────────────────────────────
input group             "── RSI ─────────────────────────────────────────────"
input bool              RSI_Rev_On      = false;       // RSI confluence for Reversal entries
input bool              RSI_Cross_On    = false;       // RSI confluence for Crossover/Retry entries
input int               RSI_Period      = 20;          // RSI Period
input double            RSI_OB_Zone     = 80.0;        // Overbought extreme zone (SELL reversal)
input double            RSI_OB_Return   = 70.0;        // RSI crosses back below this → SELL confirmed
input double            RSI_OS_Zone     = 20.0;        // Oversold extreme zone (BUY reversal)
input double            RSI_OS_Return   = 30.0;        // RSI crosses back above this → BUY confirmed
// Reversal  : RSI[2] <= RSI_OS_Zone AND RSI[1] > RSI_OS_Return  (returning from oversold → BUY)
//             RSI[2] >= RSI_OB_Zone AND RSI[1] < RSI_OB_Return  (returning from overbought → SELL)
// Crossover : RSI[1] > 50 required for BUY entries | RSI[1] < 50 required for SELL entries

// ── MA60 FAST ENTRY ───────────────────────────────────────────────
input group             "── MA60 FAST ENTRY ────────────────────────────────"
input bool              MA60_On         = false;       // Enable 60 LWMA Fast Entry strategy
input int               MA60_Period     = 60;          // LWMA Period
input int               MA60_Shift      = 5;           // LWMA Shift (bars forward on chart)
input double            MA60_ADX_Min    = 20.0;        // Min ADX for MA60 entries
input double            MA60_RSI_Buy    = 55.0;        // RSI must be >= this for BUY  (bullish momentum)
input double            MA60_RSI_Sell   = 45.0;        // RSI must be <= this for SELL (bearish momentum)
// All three conditions must fire on the SAME bar:
//   (1) RSI[1] >= MA60_RSI_Buy  (55+)                       → bullish momentum confirmed
//       RSI[1] <= MA60_RSI_Sell (45-)                       → bearish momentum confirmed
//   (2) Close[2] below LWMA60  AND Close[1] above LWMA60    → price crossed the fast MA
//   (3) ADX[1] >= MA60_ADX_Min                              → trend has sufficient strength
// EMA-200 context filter: only BUY above EMA-200 | only SELL below EMA-200
// Uses same CalcSLTP/CalcLot as all other entries. MaxEntries and TradeDir apply.
// Concurrent position ADX gate (adxSustained) uses MA60_ADX_Min, not ADX_Min.

// ── GOAL TRACKER ──────────────────────────────────────────────────
enum ENUM_GOAL_SCHEDULE { GOAL_7DAYS = 0, GOAL_WEEKDAYS = 1 };
input group             "── GOAL TRACKER ───────────────────────────────────"
input bool              Goal_On         = false;         // Enable Goal Tracker
input ENUM_GOAL_SCHEDULE Goal_Schedule  = GOAL_WEEKDAYS; // Trading days: 7-day or Weekdays only
input double            Goal_Monthly    = 500.0;         // Monthly profit target ($)
// How it works:
//   Daily target  = (Goal_Monthly - month PnL so far) / trading days remaining this month
//   Weekly target = daily target * trading days per week (5 or 7)
//   When today's closed+floating PnL >= daily target, all open positions are closed immediately
//   The target recalculates every tick so it catches up / relaxes as performance changes

// ── EA SETTINGS ───────────────────────────────────────────────────
input group             "── EA SETTINGS ───────────────────────────────────"
input int               Magic           = 20240101;     // Magic Number
input string            EA_Cmt          = "TrendFlow";  // Order Comment

//====================================================================
//  GLOBAL OBJECTS & VARIABLES
//====================================================================
CTrade        trade;
CPositionInfo pos;

int  hEMA  = INVALID_HANDLE;
int  hADX  = INVALID_HANDLE;
int  hATR  = INVALID_HANDLE;
int  hEnv  = INVALID_HANDLE;          // Envelopes (EMA 200, deviation 0.3%)
int  hRSI  = INVALID_HANDLE;          // RSI (period 20)
int  hMA60 = INVALID_HANDLE;          // LWMA-60 (shift 5) fast-entry MA

double bufEMA[], bufADX[], bufATR[];          // dynamic – required for ArraySetAsSeries
double bufEnvUp[], bufEnvDn[];                // Envelopes upper (buf 0) and lower (buf 1)
double bufRSI[];                              // RSI values
double bufMA60[];                             // LWMA-60 (shift 5) values

datetime lastBar   = 0;
double   pt        = 0.0;  // one point in price units

// Scale-In tracking  [0]=BUY side  [1]=SELL side
double   siLastPrice[2];   // price at which last SI entry was made
int      siCount[2];       // number of scale-in entries placed so far

// Pending signal state (retry logic)
bool     pendingBuy       = false;   // a buy crossover is waiting for ADX to qualify
bool     pendingSell      = false;   // a sell crossover is waiting for ADX to qualify
int      pendingBars      = 0;       // bars elapsed since delay period ended
datetime pendingTime      = 0;       // TimeCurrent() at moment crossover was detected
int      pendingCancelCnt = 0;       // consecutive bars closed on wrong side of EMA (cancel buffer)
datetime revLastEntryBar = 0;       // bar time of last reversal entry (cooldown tracking)

// SL-Flip recovery
bool     slFlipPending  = false;   // flip entry is armed and waiting
int      slFlipDir      = 0;       // +1 = fire BUY flip, -1 = fire SELL flip
datetime slFlipBarTime  = 0;       // bar open time when the SL hit occurred

// Dashboard
string PFX = "TF_";       // object name prefix
int    DX  = 15;           // X offset from corner
int    DY  = 30;           // Y offset from corner
int    DW  = 272;          // dashboard width
int    DH  = 468;          // dashboard height (added Goal Tracker section)

//====================================================================
//  ON INIT
//====================================================================
int OnInit()
{
   pt = _Point;

   // Create indicator handles
   hEMA  = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hADX  = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);   // buffer 0 = ADX line
   hATR  = iATR(_Symbol, PERIOD_CURRENT, 14);
   hEnv  = iEnvelopes(_Symbol, PERIOD_CURRENT, Env_Period, 0, MODE_EMA, PRICE_CLOSE, Env_Deviation);
   // Envelopes buffers: 0 = upper band, 1 = lower band
   hRSI  = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hMA60 = iMA(_Symbol, PERIOD_CURRENT, MA60_Period, MA60_Shift, MODE_LWMA, PRICE_CLOSE);

   if(hEMA == INVALID_HANDLE || hADX == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || hEnv == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hMA60 == INVALID_HANDLE)
   {
      Alert("TrendFlow EA: Failed to create indicator handles. EA stopped.");
      return INIT_FAILED;
   }

   ArraySetAsSeries(bufEMA,   true);
   ArraySetAsSeries(bufADX,   true);
   ArraySetAsSeries(bufATR,   true);
   ArraySetAsSeries(bufEnvUp, true);
   ArraySetAsSeries(bufEnvDn, true);

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Reset scale-in state
   siCount[0]     = 0;   siCount[1]     = 0;
   siLastPrice[0] = 0.0; siLastPrice[1] = 0.0;

   // Reset pending signal state
   pendingBuy       = false; pendingSell = false;
   pendingBars      = 0;     pendingTime = 0;
   pendingCancelCnt = 0;

   BuildDashboard();
   ChartRedraw();

   Print("TrendFlow EA v4.0 — Initialized. Magic=", Magic,
         " Symbol=", _Symbol, " TF=", EnumToString(PERIOD_CURRENT));
   return INIT_SUCCEEDED;
}

//====================================================================
//  ON DEINIT
//====================================================================
void OnDeinit(const int reason)
{
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEnv != INVALID_HANDLE) IndicatorRelease(hEnv);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMA60 != INVALID_HANDLE) IndicatorRelease(hMA60);
   DeleteDashboard();
   ChartRedraw();
   Print("TrendFlow EA: Deinitialized. Reason=", reason);
}

//====================================================================
//  ON TRADE TRANSACTION — SL-Flip detection
//  Fires on every deal execution. We look specifically for EA positions
//  closed by stop-loss with ADX >= SLFlip_ADX_Min, then arm the flip.
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(!SLFlip_On)  return;
   if(slFlipPending) return;   // a flip is already armed — don't stack

   // Only process completed deal additions
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   // Pull the deal into history so we can query its properties
   if(!HistoryDealSelect(trans.deal)) return;

   // Must be our EA on this symbol
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != Magic)   return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL)        != _Symbol) return;

   // Must be a position-closing deal
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   // Must have been closed by the stop-loss
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   if(reason != DEAL_REASON_SL) return;

   // ADX check at the moment of the SL hit (bufADX populated by preceding OnTick)
   if(ArraySize(bufADX) < 2) return;
   if(bufADX[1] < SLFlip_ADX_Min) return;

   // Determine flip direction:
   //   BUY position closed by SL → closing deal is DEAL_TYPE_SELL → flip to BUY (opposite)
   //   SELL position closed by SL → closing deal is DEAL_TYPE_BUY  → flip to SELL (opposite)
   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   slFlipDir     = (dealType == DEAL_TYPE_SELL) ? 1 : -1;
   slFlipBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   slFlipPending = true;

   Print("TrendFlow SL-Flip: armed — will enter ",
         (slFlipDir == 1 ? "BUY" : "SELL"), " in ", SLFlip_Delay,
         " bars  (ADX=", DoubleToString(bufADX[1], 1), ")");
}

//====================================================================
//  ON TICK  –  main execution loop
//====================================================================
void OnTick()
{
   // --- Always fetch latest indicator values ---
   if(CopyBuffer(hEMA, 0, 0, 4, bufEMA) < 4) return;
   if(CopyBuffer(hADX, 0, 0, 4, bufADX) < 4) return;   // buffer 0 = ADX line
   if(CopyBuffer(hATR, 0, 0, 4, bufATR) < 4) return;
   if(CopyBuffer(hRSI,  0, 0, 3, bufRSI)  < 3) return;   // need index 1 (signal bar) and 2 (prior bar)
   if(CopyBuffer(hMA60, 0, 0, 4, bufMA60) < 4) return;   // LWMA-60: need index 1 and 2 for crossover

   // Envelopes — copy enough bars for the full lookback window
   int envBars = Env_LookBack + 2;
   if(Env_On)
   {
      if(CopyBuffer(hEnv, 0, 0, envBars, bufEnvUp) < envBars) return;  // upper band
      if(CopyBuffer(hEnv, 1, 0, envBars, bufEnvDn) < envBars) return;  // lower band
   }

   // --- Tick-level management (runs on every tick) ---
   if(PT_On)    CheckProfitTarget();
   if(Goal_On)  CheckGoalDailyTarget();
   if(Trail_On) ManageTrail();
   if(BE_On)    ManageBE();
   if(SI_On)    CheckScaleIn();

   // --- Update dashboard every tick ---
   UpdateDashboard();

   // --- Bar-open gate for entry signals ---
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;

   // --- Goal Tracker: trading day gate ---
   // If weekdays-only mode is selected and today is Saturday or Sunday, suppress all entries.
   if(Goal_On && Goal_Schedule == GOAL_WEEKDAYS)
   {
      MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
      int dow = mdt.day_of_week;  // 0=Sunday, 6=Saturday
      if(dow == 0 || dow == 6) return;  // non-trading day — skip to next bar
   }

   // ── SL FLIP RECOVERY ─────────────────────────────────────────────
   // Fires on bar open once SLFlip_Delay bars have elapsed since the SL hit.
   // TradeDir is intentionally ignored — the flip always takes the opposite side.
   if(SLFlip_On && slFlipPending)
   {
      int barsElapsed = (int)((curBar - slFlipBarTime) / PeriodSeconds(PERIOD_CURRENT));
      if(barsElapsed >= SLFlip_Delay)
      {
         slFlipPending = false;   // one attempt only — clear before placing order
         if(slFlipDir == 1)       // flip BUY
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl, tp;
            CalcSLTP(ORDER_TYPE_BUY, ask, sl, tp);
            double lot = CalcLot();
            if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt + "_FLIP"))
            {
               siLastPrice[0] = ask; siCount[0] = 0;
               Print("TrendFlow SL-Flip: BUY fired after ", barsElapsed,
                     " bars  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("FLIP", ORDER_TYPE_BUY, ask, sl, tp, lot);
            }
         }
         else if(slFlipDir == -1) // flip SELL
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl, tp;
            CalcSLTP(ORDER_TYPE_SELL, bid, sl, tp);
            double lot = CalcLot();
            if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt + "_FLIP"))
            {
               siLastPrice[1] = bid; siCount[1] = 0;
               Print("TrendFlow SL-Flip: SELL fired after ", barsElapsed,
                     " bars  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("FLIP", ORDER_TYPE_SELL, bid, sl, tp, lot);
            }
         }
      }
   }

   // Closed-bar values (index 1 = last completed bar, index 2 = bar before that)
   double c1   = iClose(_Symbol, PERIOD_CURRENT, 1);
   double c2   = iClose(_Symbol, PERIOD_CURRENT, 2);
   double o1   = iOpen(_Symbol,  PERIOD_CURRENT, 1);   // signal bar open
   double hi1  = iHigh(_Symbol,  PERIOD_CURRENT, 1);   // signal bar high  (wick detection)
   double lo1  = iLow(_Symbol,   PERIOD_CURRENT, 1);   // signal bar low   (wick detection)
   double ema1 = bufEMA[1];   // EMA200 – last closed bar
   double emap = bufEMA[2];   // EMA200 – bar before that
   double adx1 = bufADX[1];   // ADX    – last closed bar
   double adx2 = bufADX[2];   // ADX    – bar before that  (sustained check)
   double atr1 = bufATR[1];   // ATR    – last closed bar
   double rsi1   = bufRSI[1];    // RSI(20) – last closed bar  (crossover gate + reversal return)
   double rsi2   = bufRSI[2];    // RSI(20) – bar before that  (reversal extreme-zone check)
   double ma60_1 = bufMA60[1];   // LWMA-60 (shift 5) – last closed bar
   double ma60_2 = bufMA60[2];   // LWMA-60 (shift 5) – bar before that  (crossover check)

   // --- Candle body filter (applied to the current bar being evaluated) ---
   double body      = MathAbs(c1 - o1);
   bool   bullClose = (c1 > o1);
   bool   bearClose = (c1 < o1);
   bool   bodyOkBuy  = !Body_On || (bullClose && body >= Body_ATR * atr1);
   bool   bodyOkSell = !Body_On || (bearClose && body >= Body_ATR * atr1);

   // --- ADX filter ---
   // adxOk        : single-bar confirmation — used for first entry only
   // adxSustained : two consecutive bars both above minimum — required before adding
   //                concurrent positions (prevents entries on brief ADX spikes)
   // adx2 already declared in bar-values block above
   bool adxOk        = !ADX_On || (adx1 >= ADX_Min);
   bool adxSustained = !ADX_On || (adx1 >= ADX_Min && adx2 >= ADX_Min);

   // --- RSI filters ---
   // Crossover gate : RSI above/below 50 at signal bar
   bool rsiOkBuy   = !RSI_Cross_On || (rsi1 > 50.0);
   bool rsiOkSell  = !RSI_Cross_On || (rsi1 < 50.0);
   // Reversal gate  : RSI returning from extreme zone (prior bar was extreme, signal bar has crossed back)
   bool rsiRevBuyOk  = !RSI_Rev_On || (rsi2 <= RSI_OS_Zone && rsi1 > RSI_OS_Return);
   bool rsiRevSellOk = !RSI_Rev_On || (rsi2 >= RSI_OB_Zone && rsi1 < RSI_OB_Return);

   // --- Raw crossover (body filter applied, ADX not yet checked) ---
   bool rawBuyCross  = (c2 < emap && c1 > ema1);
   bool rawSellCross = (c2 > emap && c1 < ema1);

   // =====================================================================
   //  ENTRY ENGINE — two modes controlled by Retry_On
   // =====================================================================
   if(!Retry_On)
   {
      // ── DIRECT MODE: crossover + body + ADX must all pass on same bar ──
      bool buyCross  = rawBuyCross  && bodyOkBuy;
      bool sellCross = rawSellCross && bodyOkSell;

      if(buyCross && TradeDir != DIR_SELL_ONLY)
      {
         int  existingBuys = CountPos(POSITION_TYPE_BUY);
         bool adxPass      = (existingBuys == 0) ? adxOk : adxSustained;  // stricter when adding
         bool noOpposite   = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_SELL) == 0) : true;
         if(adxPass && rsiOkBuy && noOpposite && existingBuys < MaxEntries)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl, tp;
            CalcSLTP(ORDER_TYPE_BUY, ask, sl, tp);
            double lot = CalcLot();
            if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt))
            {
               siLastPrice[0] = ask;
               siCount[0]     = 0;
               Print("TrendFlow: BUY opened  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("CROSSOVER", ORDER_TYPE_BUY, ask, sl, tp, lot);
            }
         }
      }

      if(sellCross && TradeDir != DIR_BUY_ONLY)
      {
         int  existingSells = CountPos(POSITION_TYPE_SELL);
         bool adxPass       = (existingSells == 0) ? adxOk : adxSustained;
         bool noOpposite    = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_BUY) == 0) : true;
         if(adxPass && rsiOkSell && noOpposite && existingSells < MaxEntries)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl, tp;
            CalcSLTP(ORDER_TYPE_SELL, bid, sl, tp);
            double lot = CalcLot();
            if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt))
            {
               siLastPrice[1] = bid;
               siCount[1]     = 0;
               Print("TrendFlow: SELL opened  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("CROSSOVER", ORDER_TYPE_SELL, bid, sl, tp, lot);
            }
         }
      }
   }
   else
   {
      // ── RETRY MODE ────────────────────────────────────────────────────
      // Step 1: On a fresh crossover (body must pass immediately)
      //         If ADX already qualifies → enter at once (no delay needed).
      //         If ADX is weak → arm the pending signal and start the timer.
      // ─────────────────────────────────────────────────────────────────
      if(rawBuyCross && bodyOkBuy && TradeDir != DIR_SELL_ONLY && !pendingBuy)
      {
         int  existingBuys = CountPos(POSITION_TYPE_BUY);
         bool adxPass      = (existingBuys == 0) ? adxOk : adxSustained;
         if(adxPass)
         {
            // ADX confirmed — enter now, no wait
            bool noOpposite = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_SELL) == 0) : true;
            if(rsiOkBuy && noOpposite && existingBuys < MaxEntries)
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double sl, tp;
               CalcSLTP(ORDER_TYPE_BUY, ask, sl, tp);
               double lot = CalcLot();
               if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt))
               {
                  siLastPrice[0] = ask;
                  siCount[0]     = 0;
                  Print("TrendFlow: BUY opened (instant)  Lot=", lot, " SL=", sl, " TP=", tp);
                  LogTradeEntry("INSTANT", ORDER_TYPE_BUY, ask, sl, tp, lot);
               }
            }
         }
         else
         {
            // ADX too weak (or unsustained for concurrent entry) — arm pending, start delay timer
            pendingBuy  = true;
            pendingSell = false;   // discard any opposite pending
            pendingBars = 0;
            pendingTime = TimeCurrent();
            Print("TrendFlow: BUY pending – ADX=", DoubleToString(adx1,1),
                  " < ", ADX_Min, ". Waiting ", Retry_DelayMinutes,
                  "m then retrying up to ", Retry_MaxBars, " bars.");
         }
      }

      if(rawSellCross && bodyOkSell && TradeDir != DIR_BUY_ONLY && !pendingSell)
      {
         int  existingSells = CountPos(POSITION_TYPE_SELL);
         bool adxPass       = (existingSells == 0) ? adxOk : adxSustained;
         if(adxPass)
         {
            bool noOpposite = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_BUY) == 0) : true;
            if(rsiOkSell && noOpposite && existingSells < MaxEntries)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double sl, tp;
               CalcSLTP(ORDER_TYPE_SELL, bid, sl, tp);
               double lot = CalcLot();
               if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt))
               {
                  siLastPrice[1] = bid;
                  siCount[1]     = 0;
                  Print("TrendFlow: SELL opened (instant)  Lot=", lot, " SL=", sl, " TP=", tp);
                  LogTradeEntry("INSTANT", ORDER_TYPE_SELL, bid, sl, tp, lot);
               }
            }
         }
         else
         {
            pendingSell = true;
            pendingBuy  = false;
            pendingBars = 0;
            pendingTime = TimeCurrent();
            Print("TrendFlow: SELL pending – ADX=", DoubleToString(adx1,1),
                  " < ", ADX_Min, ". Waiting ", Retry_DelayMinutes,
                  "m then retrying up to ", Retry_MaxBars, " bars.");
         }
      }

      // Step 2: Cancel pending only after TWO consecutive closes on the wrong side of EMA.
      // A single close below/above during a ranging phase is normal and must not kill the signal.
      if(pendingBuy)
      {
         if(c1 < ema1) pendingCancelCnt++;
         else           pendingCancelCnt = 0;   // reset on any bullish close above EMA
         if(pendingCancelCnt >= 2)
         {
            pendingBuy = false; pendingBars = 0; pendingTime = 0; pendingCancelCnt = 0;
            Print("TrendFlow: BUY pending cancelled — 2 consecutive closes below EMA200.");
         }
      }
      if(pendingSell)
      {
         if(c1 > ema1) pendingCancelCnt++;
         else           pendingCancelCnt = 0;
         if(pendingCancelCnt >= 2)
         {
            pendingSell = false; pendingBars = 0; pendingTime = 0; pendingCancelCnt = 0;
            Print("TrendFlow: SELL pending cancelled — 2 consecutive closes above EMA200.");
         }
      }

      // Step 3: Only count retry bars AFTER the delay has elapsed
      datetime delayEnd = pendingTime + (datetime)(Retry_DelayMinutes * 60);
      bool     inDelay  = (pendingBuy || pendingSell) && (TimeCurrent() < delayEnd);

      if(!inDelay && (pendingBuy || pendingSell))
         pendingBars++;

      // Step 4: Expire if max bars exceeded
      if(Retry_MaxBars > 0 && pendingBars > Retry_MaxBars)
      {
         if(pendingBuy)  Print("TrendFlow: BUY pending expired — ", pendingBars, " retry bars used.");
         if(pendingSell) Print("TrendFlow: SELL pending expired — ", pendingBars, " retry bars used.");
         pendingBuy = false; pendingSell = false;
         pendingBars = 0;    pendingTime = 0; pendingCancelCnt = 0;
      }

      // Step 5: Attempt retry entry (only after delay, only if still pending).
      // Body filter is intentionally NOT applied here — it already passed at crossover time.
      // For concurrent entries (adding to an existing position) adxSustained is required
      // so that two consecutive bars confirm the trend is genuinely recovering, not spiking.
      if(!inDelay)
      {
         if(pendingBuy)
         {
            int  existingBuys = CountPos(POSITION_TYPE_BUY);
            bool adxPass      = (existingBuys == 0) ? adxOk : adxSustained;
            bool noOpposite   = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_SELL) == 0) : true;
            if(adxPass && rsiOkBuy && noOpposite && existingBuys < MaxEntries)
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double sl, tp;
               CalcSLTP(ORDER_TYPE_BUY, ask, sl, tp);
               double lot = CalcLot();
               if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt))
               {
                  siLastPrice[0] = ask;
                  siCount[0]     = 0;
                  Print("TrendFlow: BUY opened (retry bar=", pendingBars, ")  Lot=", lot,
                        " SL=", sl, " TP=", tp);
                  LogTradeEntry("RETRY", ORDER_TYPE_BUY, ask, sl, tp, lot);
                  pendingBuy = false; pendingBars = 0; pendingTime = 0; pendingCancelCnt = 0;
               }
            }
         }

         if(pendingSell)
         {
            int  existingSells = CountPos(POSITION_TYPE_SELL);
            bool adxPass       = (existingSells == 0) ? adxOk : adxSustained;
            bool noOpposite    = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_BUY) == 0) : true;
            if(adxPass && rsiOkSell && noOpposite && existingSells < MaxEntries)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double sl, tp;
               CalcSLTP(ORDER_TYPE_SELL, bid, sl, tp);
               double lot = CalcLot();
               if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt))
               {
                  siLastPrice[1] = bid;
                  siCount[1]     = 0;
                  Print("TrendFlow: SELL opened (retry bar=", pendingBars, ")  Lot=", lot,
                        " SL=", sl, " TP=", tp);
                  LogTradeEntry("RETRY", ORDER_TYPE_SELL, bid, sl, tp, lot);
                  pendingSell = false; pendingBars = 0; pendingTime = 0; pendingCancelCnt = 0;
               }
            }
         }
      }
   } // end Retry_On

   // =====================================================================
   //  BAND-TOUCH REVERSAL ENTRY  (runs in addition to EMA crossover engine)
   //  Signal: last closed bar's WICK touches an envelope band (hi1/lo1).
   //  Compound filter: ADX >= Env_ADX_Min (default 45) — steep trend that
   //  creates the imbalance driving price into the bands.
   //  SL/TP: always static (SL_Pts / TP_Pts) regardless of TPSL_Mode.
   //    Counter-trend fades need fixed, predictable stops — ATR-scaled stops
   //    can collapse in a fast-trending market and cause premature SL hits.
   //  Cooldown: Rev_Cooldown bars must elapse between reversal entries to
   //    prevent the same condition (band + ADX) from triggering repeatedly.
   //  No retry logic — band proximity is time-sensitive.
   // =====================================================================
   if(Env_On && Env_Entry_On && ArraySize(bufEnvUp) >= 2 && ArraySize(bufEnvDn) >= 2)
   {
      bool envBuySignal  = (lo1 <= bufEnvDn[1]);  // wick touched lower band → bullish reversal
      bool envSellSignal = (hi1 >= bufEnvUp[1]);  // wick touched upper band → bearish reversal

      bool envAdxOk        = (adx1 >= Env_ADX_Min);
      bool envAdxSustained = (adx1 >= Env_ADX_Min && adx2 >= Env_ADX_Min);

      // Cooldown gate: count whole bars elapsed since last reversal entry
      datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
      int barsSinceRev = (revLastEntryBar == 0)
                         ? Rev_Cooldown
                         : (int)((curBarTime - revLastEntryBar) / PeriodSeconds(PERIOD_CURRENT));
      bool revCooldownOk = (barsSinceRev >= Rev_Cooldown);

      // --- REVERSAL BUY ---
      if(envBuySignal && envAdxOk && revCooldownOk && rsiRevBuyOk && TradeDir != DIR_SELL_ONLY)
      {
         int  existingBuys = CountPos(POSITION_TYPE_BUY);
         bool adxPass      = (existingBuys == 0) ? envAdxOk : envAdxSustained;
         bool noOpposite   = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_SELL) == 0) : true;
         if(adxPass && noOpposite && existingBuys < MaxEntries)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            // Static SL/TP — always use configured point values for reversals
            double sl = NormalizeDouble(ask - SL_Pts * pt, _Digits);
            double tp = NormalizeDouble(ask + TP_Pts * pt, _Digits);
            double lot = CalcLot();
            if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt + "_REV"))
            {
               siLastPrice[0]  = ask;
               siCount[0]      = 0;
               revLastEntryBar = curBarTime;
               Print("TrendFlow: BUY reversal — lower band wick + ADX=",
                     DoubleToString(adx1, 1), "  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("REVERSAL", ORDER_TYPE_BUY, ask, sl, tp, lot);
            }
         }
      }

      // --- REVERSAL SELL ---
      if(envSellSignal && envAdxOk && revCooldownOk && rsiRevSellOk && TradeDir != DIR_BUY_ONLY)
      {
         int  existingSells = CountPos(POSITION_TYPE_SELL);
         bool adxPass       = (existingSells == 0) ? envAdxOk : envAdxSustained;
         bool noOpposite    = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_BUY) == 0) : true;
         if(adxPass && noOpposite && existingSells < MaxEntries)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            // Static SL/TP — always use configured point values for reversals
            double sl = NormalizeDouble(bid + SL_Pts * pt, _Digits);
            double tp = NormalizeDouble(bid - TP_Pts * pt, _Digits);
            double lot = CalcLot();
            if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt + "_REV"))
            {
               siLastPrice[1]  = bid;
               siCount[1]      = 0;
               revLastEntryBar = curBarTime;
               Print("TrendFlow: SELL reversal — upper band wick + ADX=",
                     DoubleToString(adx1, 1), "  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("REVERSAL", ORDER_TYPE_SELL, bid, sl, tp, lot);
            }
         }
      }
   } // end band-touch reversal

   // =====================================================================
   //  MA60 FAST ENTRY  (third independent entry engine)
   //  Three conditions must align on the same bar:
   //    (1) RSI[1] >= MA60_RSI_Buy (55) for BUY  |  RSI[1] <= MA60_RSI_Sell (45) for SELL
   //    (2) Price crosses above/below the LWMA-60 (shift 5)
   //    (3) ADX >= MA60_ADX_Min (30)
   //  EMA-200 context: BUY only above EMA-200 | SELL only below EMA-200
   //  No retry logic — all three must fire simultaneously.
   //  Uses same CalcSLTP / CalcLot / MaxEntries / TradeDir as other engines.
   // =====================================================================
   if(MA60_On && ArraySize(bufMA60) >= 3)
   {
      // MA60 crossover on last closed bar
      bool ma60BuyCross  = (c2 < ma60_2 && c1 >= ma60_1);  // price crossed above LWMA-60
      bool ma60SellCross = (c2 > ma60_2 && c1 <= ma60_1);  // price crossed below LWMA-60

      // RSI momentum confirmation on last closed bar
      bool rsiMA60Buy    = (rsi1 >= MA60_RSI_Buy);   // RSI 55+ → bullish momentum
      bool rsiMA60Sell   = (rsi1 <= MA60_RSI_Sell);  // RSI 45- → bearish momentum

      // ADX gate — separate threshold and sustained variant for concurrent entries
      bool ma60AdxOk        = (adx1 >= MA60_ADX_Min);
      bool ma60AdxSustained = (adx1 >= MA60_ADX_Min && adx2 >= MA60_ADX_Min);

      // EMA-200 directional context
      bool ema200Bull = (c1 > ema1);
      bool ema200Bear = (c1 < ema1);

      // --- MA60 BUY ---
      if(ma60BuyCross && rsiMA60Buy && ma60AdxOk && ema200Bull && TradeDir != DIR_SELL_ONLY)
      {
         int  existingBuys = CountPos(POSITION_TYPE_BUY);
         bool adxPass      = (existingBuys == 0) ? ma60AdxOk : ma60AdxSustained;
         bool noOpposite   = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_SELL) == 0) : true;
         if(adxPass && noOpposite && existingBuys < MaxEntries)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl, tp;
            CalcSLTP(ORDER_TYPE_BUY, ask, sl, tp);
            double lot = CalcLot();
            if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt + "_MA60"))
            {
               siLastPrice[0] = ask;
               siCount[0]     = 0;
               Print("TrendFlow: MA60 BUY — RSI=", DoubleToString(rsi1,1),
                     " LWMA60=", DoubleToString(ma60_1,_Digits),
                     " ADX=", DoubleToString(adx1,1),
                     "  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("MA60", ORDER_TYPE_BUY, ask, sl, tp, lot);
            }
         }
      }

      // --- MA60 SELL ---
      if(ma60SellCross && rsiMA60Sell && ma60AdxOk && ema200Bear && TradeDir != DIR_BUY_ONLY)
      {
         int  existingSells = CountPos(POSITION_TYPE_SELL);
         bool adxPass       = (existingSells == 0) ? ma60AdxOk : ma60AdxSustained;
         bool noOpposite    = (TradeDir == DIR_BOTH) ? (CountPos(POSITION_TYPE_BUY) == 0) : true;
         if(adxPass && noOpposite && existingSells < MaxEntries)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl, tp;
            CalcSLTP(ORDER_TYPE_SELL, bid, sl, tp);
            double lot = CalcLot();
            if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt + "_MA60"))
            {
               siLastPrice[1] = bid;
               siCount[1]     = 0;
               Print("TrendFlow: MA60 SELL — RSI=", DoubleToString(rsi1,1),
                     " LWMA60=", DoubleToString(ma60_1,_Digits),
                     " ADX=", DoubleToString(adx1,1),
                     "  Lot=", lot, " SL=", sl, " TP=", tp);
               LogTradeEntry("MA60", ORDER_TYPE_SELL, bid, sl, tp, lot);
            }
         }
      }
   } // end MA60 fast entry
}

//====================================================================
//  UTILITY: COUNT EA POSITIONS
//====================================================================
int CountPos(ENUM_POSITION_TYPE type)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i))
         if(pos.Symbol() == _Symbol && pos.Magic() == Magic && pos.PositionType() == type)
            n++;
   }
   return n;
}

int TotalPos()
{
   return CountPos(POSITION_TYPE_BUY) + CountPos(POSITION_TYPE_SELL);
}

//====================================================================
//  GOAL TRACKER — CALENDAR & PnL HELPERS
//====================================================================

// Returns true if 'dow' (0=Sun…6=Sat) is a valid trading day for the chosen schedule
bool IsGoalTradingDay(int dow)
{
   if(Goal_Schedule == GOAL_7DAYS) return true;
   return (dow >= 1 && dow <= 5);  // Monday=1 … Friday=5
}

// Count trading days in the calendar month containing 'ts'
int GoalTradingDaysInMonth(datetime ts)
{
   MqlDateTime mdt; TimeToStruct(ts, mdt);
   int year = mdt.year; int month = mdt.mon;
   // Days in this month
   int daysInMonth = 31;
   if(month == 4 || month == 6 || month == 9 || month == 11) daysInMonth = 30;
   else if(month == 2)
      daysInMonth = ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) ? 29 : 28;

   int count = 0;
   MqlDateTime d; d.year = year; d.mon = month; d.hour = 12; d.min = 0; d.sec = 0;
   for(int day = 1; day <= daysInMonth; day++)
   {
      d.day = day;
      datetime t = StructToTime(d);
      MqlDateTime tmp; TimeToStruct(t, tmp);
      if(IsGoalTradingDay(tmp.day_of_week)) count++;
   }
   return (count > 0) ? count : 1;
}

// Count trading days remaining in the month from today (inclusive)
int GoalTradingDaysRemaining(datetime ts)
{
   MqlDateTime mdt; TimeToStruct(ts, mdt);
   int year = mdt.year; int month = mdt.mon;
   int daysInMonth = 31;
   if(month == 4 || month == 6 || month == 9 || month == 11) daysInMonth = 30;
   else if(month == 2)
      daysInMonth = ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) ? 29 : 28;

   int count = 0;
   MqlDateTime d; d.year = year; d.mon = month; d.hour = 12; d.min = 0; d.sec = 0;
   for(int day = mdt.day; day <= daysInMonth; day++)
   {
      d.day = day;
      datetime t = StructToTime(d);
      MqlDateTime tmp; TimeToStruct(t, tmp);
      if(IsGoalTradingDay(tmp.day_of_week)) count++;
   }
   return (count > 0) ? count : 1;
}

// Trading days per week for this schedule (used for weekly target display)
int GoalDaysPerWeek() { return (Goal_Schedule == GOAL_7DAYS) ? 7 : 5; }

// Sum closed PnL for this symbol+magic within a time window
double GoalClosedPnL(datetime fromTime, datetime toTime)
{
   double total = 0.0;
   if(!HistorySelect(fromTime, toTime)) return 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != Magic) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      total += HistoryDealGetDouble(ticket, DEAL_PROFIT)
             + HistoryDealGetDouble(ticket, DEAL_SWAP)
             + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return total;
}

// Sum open floating PnL for this symbol+magic
double GoalOpenPnL()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i))
         if(pos.Symbol() == _Symbol && pos.Magic() == Magic)
            total += pos.Profit() + pos.Swap() + pos.Commission();
   return total;
}

// Today's total PnL (closed + floating) for this symbol+magic
double GoalTodayPnL()
{
   MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
   mdt.hour = 0; mdt.min = 0; mdt.sec = 0;
   datetime dayStart = StructToTime(mdt);
   return GoalClosedPnL(dayStart, TimeCurrent()) + GoalOpenPnL();
}

// This calendar month's total closed PnL (floating excluded to avoid premature counting)
double GoalMonthPnL()
{
   MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
   mdt.day = 1; mdt.hour = 0; mdt.min = 0; mdt.sec = 0;
   datetime monthStart = StructToTime(mdt);
   return GoalClosedPnL(monthStart, TimeCurrent()) + GoalOpenPnL();
}

// Compute daily target based on remaining monthly goal and remaining trading days
double GoalDailyTarget()
{
   if(!Goal_On || Goal_Monthly <= 0.0) return 0.0;
   double remaining  = Goal_Monthly - GoalMonthPnL();
   int    daysLeft   = GoalTradingDaysRemaining(TimeCurrent());
   return remaining / daysLeft;
}

//====================================================================
//  LOT SIZE CALCULATION
//====================================================================
double CalcLot()
{
   double lot = FixedLot;

   if(LotMode == LOT_PERCENT)
   {
      double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmt  = equity * EquityPct / 100.0;
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double slDist   = SL_Pts * pt;                  // use SL_Pts as reference distance
      double riskPerLot = (slDist / tickSz) * tickVal;
      if(riskPerLot > 0.0)
         lot = riskAmt / riskPerLot;
   }

   // Normalize to broker constraints
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return lot;
}

//====================================================================
//  TP / SL CALCULATION
//====================================================================
void CalcSLTP(ENUM_ORDER_TYPE type, double price, double &sl, double &tp)
{
   if(TPSL_Mode == TPSL_STATIC)
   {
      if(type == ORDER_TYPE_BUY)
      {
         sl = price - SL_Pts * pt;
         tp = price + TP_Pts * pt;
      }
      else
      {
         sl = price + SL_Pts * pt;
         tp = price - TP_Pts * pt;
      }
   }
   else  // TPSL_DYNAMIC — ATR-based
   {
      double atrVal = bufATR[1];   // last completed bar ATR(14)
      if(type == ORDER_TYPE_BUY)
      {
         sl = price - atrVal;
         tp = price + atrVal * RR_Ratio;
      }
      else
      {
         sl = price + atrVal;
         tp = price - atrVal * RR_Ratio;
      }
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
}

//====================================================================
//  SCALE-IN  (runs every tick)
//  Adds a new position in the same direction every SI_Step points
//  of floating profit beyond the last entry, up to SI_MaxCap additions.
//====================================================================
void CheckScaleIn()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Scale-in adds to an existing position — always treat as concurrent entry.
   // Require adxSustained (two consecutive bars above ADX_Min) before adding exposure.
   if(ArraySize(bufADX) < 3) return;
   bool siAdxOk = !ADX_On || (bufADX[1] >= ADX_Min && bufADX[2] >= ADX_Min);

   // --- BUY scale-in ---
   if(siAdxOk && CountPos(POSITION_TYPE_BUY) > 0 && siCount[0] < SI_MaxCap && siLastPrice[0] > 0.0)
   {
      double profitPts = (bid - siLastPrice[0]) / pt;
      if(profitPts >= (double)SI_Step)
      {
         double sl, tp;
         CalcSLTP(ORDER_TYPE_BUY, ask, sl, tp);
         double lot = CalcLot();
         if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Cmt + "_SI"))
         {
            siLastPrice[0] = ask;
            siCount[0]++;
            Print("TrendFlow: Scale-In BUY #", siCount[0], " Lot=", lot);
            LogTradeEntry("SCALE_IN", ORDER_TYPE_BUY, ask, sl, tp, lot);
         }
      }
   }

   // --- SELL scale-in ---
   if(siAdxOk && CountPos(POSITION_TYPE_SELL) > 0 && siCount[1] < SI_MaxCap && siLastPrice[1] > 0.0)
   {
      double profitPts = (siLastPrice[1] - ask) / pt;
      if(profitPts >= (double)SI_Step)
      {
         double sl, tp;
         CalcSLTP(ORDER_TYPE_SELL, bid, sl, tp);
         double lot = CalcLot();
         if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Cmt + "_SI"))
         {
            siLastPrice[1] = bid;
            siCount[1]++;
            Print("TrendFlow: Scale-In SELL #", siCount[1], " Lot=", lot);
            LogTradeEntry("SCALE_IN", ORDER_TYPE_SELL, bid, sl, tp, lot);
         }
      }
   }

   // Reset counters when all positions of that type are closed
   if(CountPos(POSITION_TYPE_BUY)  == 0) { siCount[0] = 0; siLastPrice[0] = 0.0; }
   if(CountPos(POSITION_TYPE_SELL) == 0) { siCount[1] = 0; siLastPrice[1] = 0.0; }
}

//====================================================================
//  TRAILING STOP  (runs every tick)
//  Activates when position profit >= Trail_Trigger points.
//  Then keeps SL exactly Trail_Step points behind current price,
//  moving only in the favourable direction.
//====================================================================
void ManageTrail()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != Magic) continue;

      ulong  ticket   = pos.Ticket();
      double openPx   = pos.PriceOpen();
      double curSL    = pos.StopLoss();
      double curTP    = pos.TakeProfit();

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPx) / pt;
         if(profitPts >= (double)Trail_Trigger)
         {
            double newSL = NormalizeDouble(bid - Trail_Step * pt, _Digits);
            // Only raise SL – never lower it
            if(newSL > curSL + pt)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else  // SELL
      {
         double profitPts = (openPx - ask) / pt;
         if(profitPts >= (double)Trail_Trigger)
         {
            double newSL = NormalizeDouble(ask + Trail_Step * pt, _Digits);
            // Only lower SL – never raise it (or initialise from 0)
            if(curSL == 0.0 || newSL < curSL - pt)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//====================================================================
//  BREAK-EVEN  (runs every tick)
//  Once profit >= BE_Trigger points, moves SL to exact entry price.
//  Trail stop takes over naturally from there — no conflict.
//====================================================================
void ManageBE()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != Magic) continue;

      ulong  ticket = pos.Ticket();
      double openPx = pos.PriceOpen();
      double curSL  = pos.StopLoss();
      double curTP  = pos.TakeProfit();
      // beSL = entry price + offset in the profitable direction
      double beSL_buy  = NormalizeDouble(openPx + BE_Offset * pt, _Digits);  // buy:  SL above entry
      double beSL_sell = NormalizeDouble(openPx - BE_Offset * pt, _Digits);  // sell: SL below entry

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPx) / pt;
         // Fire once: profit threshold reached AND SL not yet at/above target
         if(profitPts >= (double)BE_Trigger && curSL < beSL_buy - pt)
            trade.PositionModify(ticket, beSL_buy, curTP);
      }
      else  // SELL
      {
         double profitPts = (openPx - ask) / pt;
         // Fire once: profit threshold reached AND SL not yet at/below target (or unset)
         if(profitPts >= (double)BE_Trigger && (curSL == 0.0 || curSL > beSL_sell + pt))
            trade.PositionModify(ticket, beSL_sell, curTP);
      }
   }
}

//====================================================================
//  GOAL TRACKER — DAILY TARGET ENFORCER  (runs every tick)
//  When Goal_On is true and today's combined P&L (closed + floating)
//  for this symbol reaches the derived daily target, close all open
//  positions on this symbol and block further entries via lot scaling.
//  This enforces the daily target as a hard ceiling, not just a nudge.
//====================================================================
void CheckGoalDailyTarget()
{
   double dailyTarget = GoalDailyTarget();
   if(dailyTarget <= 0.0) return;    // monthly goal already met — nothing to enforce

   double todayPnL = GoalTodayPnL();
   if(todayPnL < dailyTarget) return; // not there yet

   // Daily target hit — close all open positions on this symbol
   bool anyOpen = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i))
         if(pos.Symbol() == _Symbol && pos.Magic() == Magic)
            { anyOpen = true; break; }

   if(anyOpen)
   {
      Print("TrendFlow [GOAL]: Daily target hit on ", _Symbol,
            "  Today P&L=$", DoubleToString(todayPnL, 2),
            "  Target=$",    DoubleToString(dailyTarget, 2),
            "  → closing symbol positions.");
      CloseAll();
   }
}

//====================================================================
//  PROFIT TARGET  (runs every tick)
//  Closes all EA positions on THIS symbol when their combined floating
//  P&L >= PT_Amt ($).  Other instruments are unaffected.
//====================================================================
void CheckProfitTarget()
{
   // Sum profit only from positions belonging to this EA on this symbol
   double symbolPL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i))
         if(pos.Symbol() == _Symbol && pos.Magic() == Magic)
            symbolPL += pos.Profit() + pos.Swap() + pos.Commission();
   }

   if(symbolPL >= PT_Amt && PT_Amt > 0.0)
   {
      Print("TrendFlow: Profit Target hit on ", _Symbol,
            "  Float P&L=", DoubleToString(symbolPL, 2),
            " Target=$", DoubleToString(PT_Amt, 2), " → closing symbol positions.");
      CloseAll();
   }
}

//====================================================================
//  TRADE ENTRY LOGGER
//  Appends one CSV row per entry to TrendFlow_<SYMBOL>_trades.csv
//  in the terminal's MQL5/Files/ folder.  Open in Excel to pivot
//  winning vs losing trades against parameter combinations.
//
//  Columns:
//  Time | Symbol | Direction | Strategy | Price | SL | TP | Lot |
//  ADX  | EMA200 | ATR | EnvUpper | EnvLower |
//  TPSL_Mode | TradeDir | ADX_Min |
//  Retry_On | Body_On | MaxEntries |
//  Env_Entry_On | Env_ADX_Min | Rev_Cooldown |
//  SLFlip_On | SLFlip_ADX_Min | SLFlip_Delay |
//  Trail_On | BE_On | PT_On | SI_On | LotMode
//
//  Strategy tags: CROSSOVER | INSTANT | RETRY | REVERSAL | FLIP | SCALE_IN
//====================================================================
void LogTradeEntry(string strategy, ENUM_ORDER_TYPE orderType,
                   double price, double sl, double tp, double lot)
{
   // ── Experts tab output window ──────────────────────────────────────
   // Consistent prefix lets you filter all TrendFlow entries in the log
   // with a simple Ctrl+F search on "[TF-ENTRY]".
   double adxSnap = (ArraySize(bufADX) >= 2) ? bufADX[1] : 0.0;
   double emaSnap = (ArraySize(bufEMA) >= 2) ? bufEMA[1] : 0.0;
   double atrSnap = (ArraySize(bufATR) >= 2) ? bufATR[1] : 0.0;
   double rsiSnap = (ArraySize(bufRSI) >= 2) ? bufRSI[1] : 0.0;

   PrintFormat("[TF-ENTRY] %s | %s | %s | Price=%.5f SL=%.5f TP=%.5f Lot=%.2f"
               " | ADX=%.1f RSI=%.1f EMA=%.5f ATR=%.5f"
               " | ADX_Min=%.1f TPSL=%s TradeDir=%s Retry=%s Body=%s MaxEnt=%d"
               " | Env=%s EnvADX=%.1f RevCD=%d RSI_Rev=%s RSI_Cross=%s"
               " | Flip=%s FlipADX=%.1f FlipDel=%d",
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      _Symbol,
      strategy + " " + (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
      price, sl, tp, lot,
      adxSnap, rsiSnap, emaSnap, atrSnap,
      ADX_Min,
      (TPSL_Mode == TPSL_STATIC ? "STATIC" : "DYN"),
      (TradeDir == DIR_BUY_ONLY ? "BUY_ONLY" : TradeDir == DIR_SELL_ONLY ? "SELL_ONLY" : "BOTH"),
      (Retry_On    ? "Y" : "N"),
      (Body_On     ? "Y" : "N"),
      MaxEntries,
      (Env_Entry_On ? "Y" : "N"),
      Env_ADX_Min,
      Rev_Cooldown,
      (RSI_Rev_On   ? "Y" : "N"),
      (RSI_Cross_On ? "Y" : "N"),
      (SLFlip_On   ? "Y" : "N"),
      SLFlip_ADX_Min,
      SLFlip_Delay
   );
   // ──────────────────────────────────────────────────────────────────
   string fileName = "TrendFlow_" + _Symbol + "_trades.csv";

   int handle = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("TrendFlow Logger: cannot open ", fileName, "  err=", GetLastError());
      return;
   }

   // Write column headers only when the file is brand-new (empty)
   if(FileSize(handle) == 0)
   {
      FileWrite(handle,
         "Time","Symbol","Direction","Strategy",
         "Price","SL","TP","Lot",
         "ADX","RSI","EMA200","ATR","EnvUpper","EnvLower",
         "TPSL_Mode","TradeDir","ADX_Min",
         "Retry_On","Body_On","MaxEntries",
         "Env_Entry_On","Env_ADX_Min","Rev_Cooldown",
         "RSI_Rev_On","RSI_Cross_On","RSI_Period",
         "SLFlip_On","SLFlip_ADX_Min","SLFlip_Delay",
         "Trail_On","BE_On","PT_On","SI_On","LotMode"
      );
   }
   else
   {
      FileSeek(handle, 0, SEEK_END);
   }

   // Snapshot live indicator values
   double adxVal = (ArraySize(bufADX) >= 2)                   ? bufADX[1]   : 0.0;
   double emaVal = (ArraySize(bufEMA) >= 2)                   ? bufEMA[1]   : 0.0;
   double atrVal = (ArraySize(bufATR) >= 2)                   ? bufATR[1]   : 0.0;
   double rsiVal = (ArraySize(bufRSI) >= 2)                   ? bufRSI[1]   : 0.0;
   double envUp  = (Env_On && ArraySize(bufEnvUp) >= 2)       ? bufEnvUp[1] : 0.0;
   double envDn  = (Env_On && ArraySize(bufEnvDn) >= 2)       ? bufEnvDn[1] : 0.0;

   // Human-readable enums
   string dirStr      = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string tpslStr     = (TPSL_Mode == TPSL_STATIC)   ? "STATIC" : "DYNAMIC";
   string tradeDirStr = (TradeDir  == DIR_BUY_ONLY)  ? "BUY_ONLY"  :
                        (TradeDir  == DIR_SELL_ONLY)  ? "SELL_ONLY" : "BOTH";
   string lotModeStr  = (LotMode   == LOT_FIXED)     ? "FIXED" : "EQUITY%";

   FileWrite(handle,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      _Symbol,
      dirStr,
      strategy,
      DoubleToString(price,  _Digits),
      DoubleToString(sl,     _Digits),
      DoubleToString(tp,     _Digits),
      DoubleToString(lot,    2),
      DoubleToString(adxVal, 2),
      DoubleToString(rsiVal, 2),
      DoubleToString(emaVal, _Digits),
      DoubleToString(atrVal, _Digits),
      DoubleToString(envUp,  _Digits),
      DoubleToString(envDn,  _Digits),
      tpslStr,
      tradeDirStr,
      DoubleToString(ADX_Min,         1),
      (Retry_On     ? "Y" : "N"),
      (Body_On      ? "Y" : "N"),
      IntegerToString(MaxEntries),
      (Env_Entry_On ? "Y" : "N"),
      DoubleToString(Env_ADX_Min,     1),
      IntegerToString(Rev_Cooldown),
      (RSI_Rev_On   ? "Y" : "N"),
      (RSI_Cross_On ? "Y" : "N"),
      IntegerToString(RSI_Period),
      (SLFlip_On    ? "Y" : "N"),
      DoubleToString(SLFlip_ADX_Min,  1),
      IntegerToString(SLFlip_Delay),
      (Trail_On     ? "Y" : "N"),
      (BE_On        ? "Y" : "N"),
      (PT_On        ? "Y" : "N"),
      (SI_On        ? "Y" : "N"),
      lotModeStr
   );

   FileClose(handle);
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i))
         if(pos.Symbol() == _Symbol && pos.Magic() == Magic)
            trade.PositionClose(pos.Ticket());
   }
   // Reset scale-in tracking after full close
   siCount[0] = 0; siCount[1] = 0;
   siLastPrice[0] = 0.0; siLastPrice[1] = 0.0;
}

//====================================================================
//  DASHBOARD — COLOUR PALETTE
//====================================================================
// MQL5 color literals use BGR byte order: 0x00BBGGRR
// To display RGB(r,g,b) write the hex as 0xBBGGRR
#define COL_BG       (color)0x17110D   // RGB(13,17,23)    – near-black navy
#define COL_HDR      (color)0x36220F   // RGB(15,34,54)    – dark blue header
#define COL_PANEL    (color)0x221B16   // RGB(22,27,34)    – raised panel
#define COL_SEP      (color)0x403025   // RGB(37,48,64)    – separator line
#define COL_WHITE    (color)0xF0EBE8   // RGB(232,235,240) – off-white text
#define COL_DIM      (color)0x807060   // RGB(96,112,128)  – dim/label text
#define COL_GREEN    (color)0x53C800   // RGB(0,200,83)    – bullish / active
#define COL_RED      (color)0x573DFF   // RGB(255,61,87)   – bearish / loss
#define COL_YELLOW   (color)0x00D6FF   // RGB(255,214,0)   – warning / ranging
#define COL_BLUE     (color)0xFF8A44   // RGB(68,138,255)  – EMA value accent
#define COL_TEAL     (color)0xA5BF00   // RGB(0,191,165)   – WMA value accent

//====================================================================
//  DASHBOARD — OBJECT HELPERS
//====================================================================
void MakeRect(string name, int x, int y, int w, int h,
              color bg, color border = clrNONE, int bw = 0)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, name, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR,       (border == clrNONE) ? bg : border);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,       bw);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,      true);
   ObjectSetInteger(0, name, OBJPROP_BACK,        false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,      0);
}

void MakeLabel(string name, int x, int y, string text,
               color clr, int sz = 8, string font = "Segoe UI")
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   sz);
   ObjectSetString( 0, name, OBJPROP_FONT,       font);
   ObjectSetString( 0, name, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,     1);
}

void SetLabel(string name, string text, color clr)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetString( 0, name, OBJPROP_TEXT,  text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }
}

//====================================================================
//  DASHBOARD — BUILD  (called once in OnInit)
//====================================================================
void BuildDashboard()
{
   int x = DX, y = DY, w = DW;
   int p = 13;   // left padding inside panel

   //--- Outer container + border
   MakeRect(PFX+"bg",   x-1, y-1, w+2, DH+2, COL_SEP);   // border layer
   MakeRect(PFX+"body", x,   y,   w,   DH,   COL_BG);

   //--- Header bar ─────────────────────────────────────────────────
   MakeRect(PFX+"hdr", x, y, w, 30, COL_HDR);
   MakeLabel(PFX+"hdr_ico",  x+p,      y+8,  "◈",         COL_TEAL,  11, "Segoe UI");
   MakeLabel(PFX+"hdr_name", x+p+18,   y+9,  "TRENDFLOW EA", COL_WHITE, 9, "Segoe UI Semibold");
   MakeLabel(PFX+"hdr_ver",  x+w-38,   y+10, "v 4.0",     COL_DIM,   7);

   //--- Symbol / TF strip ──────────────────────────────────────────
   MakeRect(PFX+"sym_bg", x, y+30, w, 18, COL_PANEL);
   MakeLabel(PFX+"sym",   x+p,    y+34, _Symbol + "  ·  " + GetTFStr(), COL_DIM, 7);
   MakeLabel(PFX+"magic", x+w-70, y+34, "Magic " + IntegerToString(Magic), COL_DIM, 7);

   MakeRect(PFX+"sep0", x, y+48, w, 1, COL_SEP);

   //--- SECTION 1: MARKET STATUS ────────────────────────────────────
   MakeLabel(PFX+"s1_hdr", x+p, y+53, "MARKET STATUS", COL_DIM, 7);

   // Trend row
   MakeLabel(PFX+"lbl_trend",  x+p,    y+68, "Trend",   COL_DIM, 8);
   MakeLabel(PFX+"val_trend",  x+p+90, y+68, "──────",  COL_DIM, 8, "Segoe UI Semibold");

   // ADX row
   MakeLabel(PFX+"lbl_adx",   x+p,    y+83, "ADX",     COL_DIM, 8);
   MakeLabel(PFX+"val_adx",   x+p+90, y+83, "──────",  COL_DIM, 8, "Segoe UI Semibold");

   // Signal row
   MakeLabel(PFX+"lbl_sig",   x+p,    y+98, "Signal",  COL_DIM, 8);
   MakeLabel(PFX+"val_sig",   x+p+90, y+98, "──────",  COL_DIM, 8, "Segoe UI Semibold");

   // Envelope reversal narrative row (NEW)
   MakeLabel(PFX+"lbl_rev",   x+p,    y+113, "Reversal", COL_DIM, 8);
   MakeLabel(PFX+"val_rev",   x+p+90, y+113, "──────",   COL_DIM, 8, "Segoe UI Semibold");

   // EMA200 value
   MakeLabel(PFX+"lbl_ema",   x+p,    y+128, "EMA 200", COL_DIM,  7);
   MakeLabel(PFX+"val_ema",   x+p+62, y+128, "──────",  COL_BLUE, 7);

   // RSI row
   MakeLabel(PFX+"lbl_rsi",   x+p,    y+143, "RSI(20)", COL_DIM,  8);
   MakeLabel(PFX+"val_rsi",   x+p+90, y+143, "──────",  COL_DIM,  8, "Segoe UI Semibold");

   // Body Filter row
   MakeLabel(PFX+"lbl_body",  x+p,    y+157, "Body",    COL_DIM,  8);
   MakeLabel(PFX+"val_body",  x+p+90, y+157, "──────",  COL_DIM,  8, "Segoe UI Semibold");

   MakeRect(PFX+"sep1", x, y+172, w, 1, COL_SEP);

   //--- SECTION 2: POSITIONS ────────────────────────────────────────
   MakeLabel(PFX+"s2_hdr", x+p, y+177, "POSITIONS", COL_DIM, 7);

   MakeLabel(PFX+"lbl_total", x+p,     y+192, "Open Trades", COL_DIM, 8);
   MakeLabel(PFX+"val_total", x+p+110, y+192, "0 / " + IntegerToString(MaxEntries), COL_WHITE, 8, "Segoe UI Semibold");

   MakeLabel(PFX+"lbl_bs",    x+p,     y+207, "Buys / Sells", COL_DIM, 8);
   MakeLabel(PFX+"val_bs",    x+p+110, y+207, "0 / 0", COL_WHITE, 8);

   MakeLabel(PFX+"lbl_si",    x+p,     y+222, "Scale-In", COL_DIM, 8);
   MakeLabel(PFX+"val_si",    x+p+110, y+222, SI_On ? "0 / " + IntegerToString(SI_MaxCap) : "OFF",
             SI_On ? COL_WHITE : COL_DIM, 8);

   MakeRect(PFX+"sep2", x, y+237, w, 1, COL_SEP);

   //--- SECTION 3: ACCOUNT ──────────────────────────────────────────
   MakeLabel(PFX+"s3_hdr", x+p, y+242, "ACCOUNT", COL_DIM, 7);

   MakeLabel(PFX+"lbl_bal",  x+p,     y+257, "Balance",   COL_DIM, 8);
   MakeLabel(PFX+"val_bal",  x+p+110, y+257, "──────",    COL_WHITE, 8, "Segoe UI Semibold");

   MakeLabel(PFX+"lbl_eq",   x+p,     y+272, "Equity",    COL_DIM, 8);
   MakeLabel(PFX+"val_eq",   x+p+110, y+272, "──────",    COL_WHITE, 8, "Segoe UI Semibold");

   MakeLabel(PFX+"lbl_pnl",  x+p,     y+287, "Float P&L", COL_DIM, 8);
   MakeLabel(PFX+"val_pnl",  x+p+110, y+287, "──────",    COL_WHITE, 8, "Segoe UI Semibold");

   MakeRect(PFX+"sep3", x, y+303, w, 1, COL_SEP);

   //--- SECTION 4: GOAL TRACKER ──────────────────────────────────────
   MakeLabel(PFX+"s4_hdr",    x+p,    y+308, "GOAL TRACKER", COL_DIM, 7);

   // Labels (static)
   MakeLabel(PFX+"lbl_gmonth", x+p,    y+323, "Monthly",    COL_DIM, 8);
   MakeLabel(PFX+"val_gmonth", x+p+90, y+323, "──────",     COL_DIM, 8, "Segoe UI Semibold");
   MakeLabel(PFX+"lbl_gweek",  x+p,    y+338, "This Week",  COL_DIM, 8);
   MakeLabel(PFX+"val_gweek",  x+p+90, y+338, "──────",     COL_DIM, 8, "Segoe UI Semibold");
   MakeLabel(PFX+"lbl_gday",   x+p,    y+353, "Daily",      COL_DIM, 8);
   MakeLabel(PFX+"val_gday",   x+p+90, y+353, "──────",     COL_DIM, 8, "Segoe UI Semibold");
   MakeLabel(PFX+"lbl_gtoday", x+p,    y+368, "Today",      COL_DIM, 8);
   MakeLabel(PFX+"val_gtoday", x+p+90, y+368, "──────",     COL_DIM, 8, "Segoe UI Semibold");

   MakeRect(PFX+"sep4", x, y+388, w, 1, COL_SEP);

   //--- SECTION 5: SETTINGS FOOTER ──────────────────────────────────
   MakeLabel(PFX+"s5_hdr", x+p, y+393, "SETTINGS", COL_DIM, 7);

   string ft1 = "Dir: " + GetDirStr() + "   Lot: " + GetLotStr() + "   TP/SL: " + GetTPSLStr();
   string ft2 = "Tr: "  + (Trail_On   ? IntegerToString(Trail_Step)   + "p" : "OFF") +
                "  BE: " + (BE_On      ? IntegerToString(BE_Trigger)   + "p" : "OFF") +
                "  PT: " + (PT_On      ? "$" + DoubleToString(PT_Amt, 2)     : "OFF") +
                "  SI: " + (SI_On      ? IntegerToString(SI_MaxCap) + " cap" : "OFF") +
                "  SLF:" + (SLFlip_On  ? "ON" : "OFF");

   MakeLabel(PFX+"ft1",    x+p, y+407, ft1, COL_DIM, 7);
   MakeLabel(PFX+"ft2",    x+p, y+421, ft2, COL_DIM, 7);
   // Flip-armed alert row (hidden unless armed)
   MakeLabel(PFX+"ft_flip", x+p, y+435, "", COL_DIM, 7);
}

//====================================================================
//  DASHBOARD — UPDATE  (called every tick)
//====================================================================
void UpdateDashboard()
{
   // Safety: ensure core buffers are fresh
   if(ArraySize(bufEMA) < 3 || ArraySize(bufADX) < 3) return;
   // Note: envelope buffers checked inline in the reversal block below

   double c1   = iClose(_Symbol, PERIOD_CURRENT, 1);
   double c2   = iClose(_Symbol, PERIOD_CURRENT, 2);
   double ema1 = bufEMA[1];   // EMA200 bar[1]
   double emap = bufEMA[2];   // EMA200 bar[2]
   double adx1 = bufADX[1];   // ADX    bar[1]
   double rsi1   = (ArraySize(bufRSI)  >= 3) ? bufRSI[1]  : 50.0;
   double rsi2   = (ArraySize(bufRSI)  >= 3) ? bufRSI[2]  : 50.0;
   double ma60_1 = (ArraySize(bufMA60) >= 3) ? bufMA60[1] : 0.0;
   double ma60_2 = (ArraySize(bufMA60) >= 3) ? bufMA60[2] : 0.0;

   // Trend (price vs EMA200)
   bool   bull     = (c1 > ema1);
   string trendTxt = bull ? "BULLISH  ▲" : "BEARISH  ▼";
   color  trendClr = bull ? COL_GREEN : COL_RED;

   // Signal — EMA200 crossover or pending retry state
   bool   buyCross  = (c2 < emap && c1 > ema1);
   bool   sellCross = (c2 > emap && c1 < ema1);
   string sigTxt;
   color  sigClr;

   if(Retry_On && pendingBuy)
   {
      datetime delayEnd = pendingTime + (datetime)(Retry_DelayMinutes * 60);
      if(TimeCurrent() < delayEnd)
      {
         int secsLeft = (int)(delayEnd - TimeCurrent());
         int minsLeft = secsLeft / 60 + 1;
         sigTxt = "AWAIT BUY ◈  " + IntegerToString(minsLeft) + "m";
      }
      else
         sigTxt = "AWAIT BUY ◈  " + IntegerToString(pendingBars) +
                  (Retry_MaxBars > 0 ? "/" + IntegerToString(Retry_MaxBars) : "") + "b";
      sigClr = COL_YELLOW;
   }
   else if(Retry_On && pendingSell)
   {
      datetime delayEnd = pendingTime + (datetime)(Retry_DelayMinutes * 60);
      if(TimeCurrent() < delayEnd)
      {
         int secsLeft = (int)(delayEnd - TimeCurrent());
         int minsLeft = secsLeft / 60 + 1;
         sigTxt = "AWAIT SELL ◈  " + IntegerToString(minsLeft) + "m";
      }
      else
         sigTxt = "AWAIT SELL ◈  " + IntegerToString(pendingBars) +
                  (Retry_MaxBars > 0 ? "/" + IntegerToString(Retry_MaxBars) : "") + "b";
      sigClr = COL_YELLOW;
   }
   else if(buyCross)       { sigTxt = "BUY  ▲";       sigClr = COL_GREEN; }
   else if(sellCross)      { sigTxt = "SELL  ▼";      sigClr = COL_RED;   }
   else
   {
      // Check MA60 fast entry signal
      bool ma60DashBuy  = MA60_On && ArraySize(bufMA60) >= 3 &&
                          (c2 < ma60_2 && c1 >= ma60_1) &&
                          (rsi1 >= MA60_RSI_Buy) &&
                          (adx1 >= MA60_ADX_Min) && (c1 > ema1);
      bool ma60DashSell = MA60_On && ArraySize(bufMA60) >= 3 &&
                          (c2 > ma60_2 && c1 <= ma60_1) &&
                          (rsi1 <= MA60_RSI_Sell) &&
                          (adx1 >= MA60_ADX_Min) && (c1 < ema1);

      // Check for active band-touch reversal signal (wick + ADX >= Env_ADX_Min)
      bool revBuy  = Env_On && Env_Entry_On && ArraySize(bufEnvDn) >= 2 &&
                     (iLow(_Symbol, PERIOD_CURRENT, 1) <= bufEnvDn[1]) &&
                     (adx1 >= Env_ADX_Min);
      bool revSell = Env_On && Env_Entry_On && ArraySize(bufEnvUp) >= 2 &&
                     (iHigh(_Symbol, PERIOD_CURRENT, 1) >= bufEnvUp[1]) &&
                     (adx1 >= Env_ADX_Min);

      if(ma60DashBuy)       { sigTxt = "MA60 BUY  ▲";  sigClr = COL_GREEN; }
      else if(ma60DashSell) { sigTxt = "MA60 SELL  ▼"; sigClr = COL_RED;   }
      else if(revBuy)       { sigTxt = "REV BUY  ▲";   sigClr = COL_TEAL;  }
      else if(revSell)      { sigTxt = "REV SELL  ▼";  sigClr = COL_TEAL;  }
      else                  { sigTxt = "NONE  ──";      sigClr = COL_DIM;   }
   }

   SetLabel(PFX+"val_trend", trendTxt, trendClr);
   SetLabel(PFX+"val_sig",   sigTxt,   sigClr);
   // ADX status
   string adxTxt; color adxClr;
   if(!ADX_On)             { adxTxt = "DISABLED";                              adxClr = COL_DIM;    }
   else if(adx1 >= ADX_Min){ adxTxt = DoubleToString(adx1,1) + "  TRENDING  ✓"; adxClr = COL_GREEN;  }
   else                    { adxTxt = DoubleToString(adx1,1) + "  WEAK  ◈";     adxClr = COL_YELLOW; }
   SetLabel(PFX+"val_adx", adxTxt, adxClr);

   // Envelope reversal narrative — scan last Env_LookBack bars for band touches
   string revTxt; color revClr;
   if(!Env_On || ArraySize(bufEnvUp) < Env_LookBack + 1 || ArraySize(bufEnvDn) < Env_LookBack + 1)
   {
      revTxt = Env_On ? "──────" : "DISABLED";
      revClr = COL_DIM;
   }
   else
   {
      bool revBull = false;   // low touched lower band → bullish reversal narrative
      bool revBear = false;   // high touched upper band → bearish reversal narrative
      for(int i = 1; i <= Env_LookBack; i++)
      {
         if(i >= ArraySize(bufEnvUp)) break;
         if(iHigh(_Symbol, PERIOD_CURRENT, i) >= bufEnvUp[i]) revBear = true;
         if(iLow(_Symbol,  PERIOD_CURRENT, i) <= bufEnvDn[i]) revBull = true;
      }
      if(revBull && revBear) { revTxt = "SQUEEZE ◈";       revClr = COL_YELLOW; }
      else if(revBull)       { revTxt = "BULL REVERSAL ▲"; revClr = COL_GREEN;  }
      else if(revBear)       { revTxt = "BEAR REVERSAL ▼"; revClr = COL_RED;    }
      else                   { revTxt = "NO SETUP  ──";    revClr = COL_DIM;    }
   }
   SetLabel(PFX+"val_rev", revTxt, revClr);

   SetLabel(PFX+"val_ema",  DoubleToString(ema1, _Digits), COL_BLUE);

   // RSI status
   if(ArraySize(bufRSI) >= 2)
   {
      double rsiVal = bufRSI[1];
      string rsiTxt; color rsiClr;
      if     (rsiVal >= RSI_OB_Zone)   { rsiTxt = DoubleToString(rsiVal,1) + "  OVERBOUGHT ▲"; rsiClr = COL_RED;    }
      else if(rsiVal >= RSI_OB_Return) { rsiTxt = DoubleToString(rsiVal,1) + "  ELEVATED";     rsiClr = COL_YELLOW; }
      else if(rsiVal <= RSI_OS_Zone)   { rsiTxt = DoubleToString(rsiVal,1) + "  OVERSOLD ▼";   rsiClr = COL_GREEN;  }
      else if(rsiVal <= RSI_OS_Return) { rsiTxt = DoubleToString(rsiVal,1) + "  DEPRESSED";    rsiClr = COL_YELLOW; }
      else                             { rsiTxt = DoubleToString(rsiVal,1) + "  NEUTRAL";       rsiClr = COL_DIM;    }
      SetLabel(PFX+"val_rsi", rsiTxt, rsiClr);
   }

   // Body Filter row
   // Shows: actual body / minimum required body, and pass/fail state
   {
      double body    = MathAbs(iClose(_Symbol, PERIOD_CURRENT, 1) -
                               iOpen (_Symbol, PERIOD_CURRENT, 1));
      double minBody = Body_ATR * (ArraySize(bufATR) >= 2 ? bufATR[1] : 0.0);
      bool   bullBar = (iClose(_Symbol, PERIOD_CURRENT, 1) > iOpen(_Symbol, PERIOD_CURRENT, 1));
      bool   bearBar = (iClose(_Symbol, PERIOD_CURRENT, 1) < iOpen(_Symbol, PERIOD_CURRENT, 1));

      string bodyTxt; color bodyClr;
      if(!Body_On)
      {
         bodyTxt = "DISABLED";
         bodyClr = COL_DIM;
      }
      else if(minBody <= 0.0)
      {
         bodyTxt = "──────";
         bodyClr = COL_DIM;
      }
      else
      {
         // Express both values in points for readability
         double bodyPts   = body    / pt;
         double minPts    = minBody / pt;
         double pct       = (minBody > 0.0) ? (body / minBody) * 100.0 : 0.0;
         bool   passDir   = (bullBar || bearBar);       // has a defined direction
         bool   passSz    = (body >= minBody);          // meets size threshold
         bool   passes    = passDir && passSz;

         string arrow = bullBar ? "▲" : (bearBar ? "▼" : "─");
         bodyTxt = arrow + " " + DoubleToString(bodyPts, 1) + "p / " +
                   DoubleToString(minPts, 1) + "p  (" +
                   DoubleToString(pct, 0) + "%)";

         if(passes)       bodyClr = COL_GREEN;
         else if(pct > 50) bodyClr = COL_YELLOW;
         else              bodyClr = COL_RED;
      }
      SetLabel(PFX+"val_body", bodyTxt, bodyClr);
   }

   // Positions
   int buys  = CountPos(POSITION_TYPE_BUY);
   int sells = CountPos(POSITION_TYPE_SELL);
   int total = buys + sells;
   color posClr = (total > 0) ? COL_WHITE : COL_DIM;
   SetLabel(PFX+"val_total", IntegerToString(total) + " / " + IntegerToString(MaxEntries), posClr);
   SetLabel(PFX+"val_bs",    IntegerToString(buys) + " / " + IntegerToString(sells),       posClr);

   if(SI_On)
   {
      int siTotal = siCount[0] + siCount[1];
      string siTxt = IntegerToString(siTotal) + " / " + IntegerToString(SI_MaxCap * 2);
      SetLabel(PFX+"val_si", siTxt, siTotal > 0 ? COL_YELLOW : COL_WHITE);
   }

   // Account
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double floatPL = equity - balance;
   string cur     = AccountInfoString(ACCOUNT_CURRENCY);

   SetLabel(PFX+"val_bal", cur + " " + DoubleToString(balance, 2), COL_WHITE);
   SetLabel(PFX+"val_eq",  cur + " " + DoubleToString(equity,  2), COL_WHITE);

   string plSign = (floatPL >= 0) ? "+" : "";
   color  plClr  = (floatPL >= 0) ? COL_GREEN : COL_RED;
   SetLabel(PFX+"val_pnl", plSign + DoubleToString(floatPL, 2) + " " + cur, plClr);

   // SL-Flip armed alert
   if(SLFlip_On && slFlipPending)
   {
      int barsLeft = SLFlip_Delay -
                     (int)((iTime(_Symbol, PERIOD_CURRENT, 0) - slFlipBarTime) / PeriodSeconds(PERIOD_CURRENT));
      barsLeft = MathMax(barsLeft, 0);
      string flipTxt = "FLIP ARMED: " + (slFlipDir == 1 ? "BUY" : "SELL") +
                       "  (" + IntegerToString(barsLeft) + " bars)";
      SetLabel(PFX+"ft_flip", flipTxt, COL_YELLOW);
   }
   else
   {
      SetLabel(PFX+"ft_flip", "", COL_DIM);
   }

   // ── GOAL TRACKER section ─────────────────────────────────────────
   if(Goal_On)
   {
      string cur = AccountInfoString(ACCOUNT_CURRENCY);

      // Current P&L figures
      double monthPnL   = GoalMonthPnL();
      double todayPnL   = GoalTodayPnL();
      double dailyTgt   = GoalDailyTarget();
      double weeklyTgt  = dailyTgt * GoalDaysPerWeek();
      double remaining  = Goal_Monthly - monthPnL;

      // Monthly row: "Target $500  Made $123.45"
      string monthSign = (monthPnL >= 0) ? "+" : "";
      string monthTxt  = "Tgt $" + DoubleToString(Goal_Monthly, 2) +
                         "  Made " + monthSign + DoubleToString(monthPnL, 2);
      color  monthClr  = (monthPnL >= Goal_Monthly) ? COL_GREEN :
                         (monthPnL >= Goal_Monthly * 0.5) ? COL_YELLOW : COL_DIM;
      SetLabel(PFX+"val_gmonth", monthTxt, monthClr);

      // Weekly target row: "Wk $XX.XX  Left $XX.XX"
      string weekTxt = "Wk $" + DoubleToString(weeklyTgt, 2) +
                       "  Left $" + DoubleToString(MathMax(remaining, 0.0), 2);
      SetLabel(PFX+"val_gweek", weekTxt, COL_DIM);

      // Daily target row: "Day $XX.XX  [days left]d"
      int dLeft = GoalTradingDaysRemaining(TimeCurrent());
      string schedule = (Goal_Schedule == GOAL_7DAYS) ? "7d" : "5d";
      string dayTxt = "Day $" + DoubleToString(MathMax(dailyTgt, 0.0), 2) +
                      "  " + IntegerToString(dLeft) + " days (" + schedule + ")";
      SetLabel(PFX+"val_gday", dayTxt, COL_DIM);

      // Today row — coloured by progress vs daily target
      string todaySign = (todayPnL >= 0) ? "+" : "";
      string todayTxt;
      color  todayClr;
      if(dailyTgt <= 0.0)
      {
         // Monthly goal already exceeded — display as bonus
         todayTxt = todaySign + DoubleToString(todayPnL, 2) + "  GOAL MET ✓";
         todayClr = COL_GREEN;
      }
      else if(todayPnL >= dailyTgt)
      {
         todayTxt = todaySign + DoubleToString(todayPnL, 2) + "  TARGET HIT ✓";
         todayClr = COL_GREEN;
      }
      else if(todayPnL >= dailyTgt * 0.5)
      {
         todayTxt = todaySign + DoubleToString(todayPnL, 2) +
                    " / $" + DoubleToString(dailyTgt, 2) + "  ◈";
         todayClr = COL_YELLOW;
      }
      else
      {
         todayTxt = todaySign + DoubleToString(todayPnL, 2) +
                    " / $" + DoubleToString(dailyTgt, 2);
         todayClr = COL_RED;
      }
      SetLabel(PFX+"val_gtoday", todayTxt, todayClr);
   }
   else
   {
      SetLabel(PFX+"val_gmonth", "DISABLED", COL_DIM);
      SetLabel(PFX+"val_gweek",  "──────",   COL_DIM);
      SetLabel(PFX+"val_gday",   "──────",   COL_DIM);
      SetLabel(PFX+"val_gtoday", "──────",   COL_DIM);
   }

   ChartRedraw();
}

//====================================================================
//  DASHBOARD — DELETE  (called in OnDeinit)
//====================================================================
void DeleteDashboard()
{
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i);
      if(StringSubstr(nm, 0, StringLen(PFX)) == PFX)
         ObjectDelete(0, nm);
   }
}

//====================================================================
//  HELPER STRINGS
//====================================================================
string GetTFStr()
{
   switch((int)PERIOD_CURRENT)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
      default:         return "??";
   }
}

string GetDirStr()
{
   if(TradeDir == DIR_BUY_ONLY)  return "BUY";
   if(TradeDir == DIR_SELL_ONLY) return "SELL";
   return "BOTH";
}

string GetLotStr()
{
   if(LotMode == LOT_FIXED)
      return DoubleToString(FixedLot, 2) + " FX";
   return DoubleToString(EquityPct, 1) + "% EQ";
}

string GetTPSLStr()
{
   return (TPSL_Mode == TPSL_STATIC) ? "STATIC" : "DYNAMIC";
}
//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
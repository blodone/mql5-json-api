//+------------------------------------------------------------------+
//
// Copyright (C) 2019 Ramon Martin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// NO LIABILITY FOR CONSEQUENTIAL DAMAGES
//
// In no event shall the author be liable for any damages whatsoever
// (including, without limitation, incidental, direct, indirect and
// consequential damages, damages for loss of business profits,
// business interruption, loss of business information, or other
// pecuniary loss) arising out of the use or inability to use this
// product, even if advised of the possibility of such damages.
//+--------------------------------------------------------------------+

#property copyright "Copyright 2019, Ramon Martin."
#property link "https://github.com/parrondo/MQL5-JSON-API"
#define EXPERT_VERSION "1.0"
#property version EXPERT_VERSION
#property description "MQL5 JSON API"
#property description "See github link for documentation"

// Required: MQL-ZMQ from https://github.com/dingmaotu/mql-zmq
// References:
// https://github.com/khramkov/MQL-JSON-API
// https://github.com/darwinex/dwx-zeromq-connector

//////////////////////////////////////////////////////////////////////
#include <Arrays\ArrayString.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/DealInfo.mqh>
#include <Trade/Trade.mqh>
#include <Zmq/Zmq.mqh>

#include <JsonAPI/Helpers.mqh>
#include <JsonAPI/Json.mqh>
#include <JsonAPI/MsgStringToInteger.mqh>
//////////////////////////////////////////////////////////////////////


// --------------------    External variables   ------------------- //
input string z0 = "--- ZeroMQ Configuration ---";
input string PROJECT_NAME = "MQL5 JSON API";
input string ZEROMQ_PROTOCOL = "tcp";
input string HOST = "*";
input int SYS_PORT = 15555;
input int DATA_PORT = 15556;
input int LIVE_PORT = 15557;
input int STR_PORT = 15558;
input int MILLISECOND_TIMER = 1;

input string a0 = "--- Add as many accounts as necessary ---";
input string authAccounts = "123456,123457,123458"; // Write here your trading accounts
input bool checkAccounts = true; // Check accounts enabled

input string o0 = "--- Options ---";
input string o1 = "--- Wrtite to log file ---";
input bool writeLogFile = false;
input string o2 = "--- Information about an instrument ---";
input string examine = "EURUSD";
input string o3 = "--- Print the account values every LOG_ACCOUNT minutes ---";
input int logAccount = 0;
input string o4 = "--- Push last candle to liveSocket ---";
input bool liveData = true;

// --------------------    Global variables   --------------------- //
// General
bool debug = true;
bool connectedFlag = true;
datetime lastBar = 0;
datetime tm;
ENUM_TIMEFRAMES periodTF = _Period;  //Period of the requested HISTORY
string _symbol = _Symbol;
string EAversion = EXPERT_VERSION;
int logLines = 0; // Log file line counter
int maxLogLinesInFile = 2000; // Maximum lines in log file
ulong magicNumber = 1234; //EA magic number
int _fileHandle = -1; // Aux for log file management


// Prepare context and sockets
Context context("MQL5 JSON API");

// System socket receives requests from client and replies 'OK'.
// and the reply results/errors is sending via Data socket.
Socket sysSocket(context, ZMQ_REP);

// Data socket reply results/errors requested via System socket.
Socket dataSocket(context, ZMQ_PUSH);

// Live socket. When everything is OK send status "CONNECTED" and candle closed data.
// If the terminal lost connection to the market, send status "DISCONNECTED".
Socket liveSocket(context, ZMQ_PUSH);

/* Streaming socket when performing some definite actions on a trade account.
Those evente are handled by OnTradeTransaction function.
The following trade transactions generate messages for this socket:
    handling a trade request;
    changing open orders;
    changing orders history;
    changing deals history;
    changing positions.
*/
Socket streamSocket(context, ZMQ_PUSH);

//-- Assign client "action", "actionType" and "timeFrame" in order to process them.
void MsgStringToInteger::InitializeCArrayString();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//-- Assign client "action", "actionType" and "timeFrame" in order to process them.
   MsgStringToInteger::InitializeCArrayString();

//--
   InitialChecking(examine, logAccount, authAccounts, checkAccounts, writeLogFile, EAversion);

//-- OnTimer() function event generation time
   EventSetMillisecondTimer(MILLISECOND_TIMER);  // Set Millisecond Timer to get client socket input

//
//-- Binding ZMQ ports on init
//

//-- System socket
   Print("Binding 'System' socket on port " + IntegerToString(SYS_PORT) + "...");
   sysSocket.bind(StringFormat("%s://%s:%d", ZEROMQ_PROTOCOL, HOST, SYS_PORT));
   sysSocket.setLinger(0);             //Set linger period for socket shutdown
   sysSocket.setSendHighWaterMark(1);  // Number of messages to buffer in RAM.

//-- Data socket
   Print("Binding 'Data' socket on port " + IntegerToString(DATA_PORT) + "...");
   dataSocket.bind(StringFormat("%s://%s:%d", ZEROMQ_PROTOCOL, HOST, DATA_PORT));
   dataSocket.setLinger(0);             //Set linger period for socket shutdown
   dataSocket.setSendHighWaterMark(5);  // Number of messages to buffer in RAM.

//-- Live socket
   Print("Binding 'Live' socket on port " + IntegerToString(LIVE_PORT) + "...");
   liveSocket.bind(StringFormat("%s://%s:%d", ZEROMQ_PROTOCOL, HOST, LIVE_PORT));
   liveSocket.setLinger(0);             //Set linger period for socket shutdown
   liveSocket.setSendHighWaterMark(1);  // Number of messages to buffer in RAM.

//-- Streaming socket
   Print("Binding 'Streaming' socket on port " + IntegerToString(STR_PORT) + "...");
   streamSocket.bind(StringFormat("%s://%s:%d", ZEROMQ_PROTOCOL, HOST, STR_PORT));
   streamSocket.setLinger(0);              //Set linger period for socket shutdown
   streamSocket.setSendHighWaterMark(50);  // Number of messages to buffer in RAM.

//--
   Print("JsonAPI EA ",EXPERT_VERSION," - Timer ",MILLISECOND_TIMER," ms");
   Comment("JsonAPI at the controls ",EXPERT_VERSION);

   return (INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//-- Unbinding ZMQ ports on denit
   Print(__FUNCTION__, " Deinitialization reason code = ", reason);

//--- Deinitialization reason code
   Print("UninitializeReason() = ",getUninitReasonText(_UninitReason));
// switch ready to manage another reasons
   switch(reason)
     {
      case 3://"Symbol or timeframe was changed"
         Print("OnDeinit ...");
         break;
      default:
         //-- Deleting CArrayString
         MsgStringToInteger::deleteCArrayString();

         //-- Clossing log file
         if(writeLogFile)
            CloseLogFile();
         //--- Unbinding ZeroMQ sockets
         Print("Unbinding 'System' socket on port " + IntegerToString(SYS_PORT) + "..");
         sysSocket.unbind(StringFormat("tcp://%s:%d", HOST, SYS_PORT));

         Print("Unbinding 'Data' socket on port " + IntegerToString(DATA_PORT) + "..");
         dataSocket.unbind(StringFormat("tcp://%s:%d", HOST, DATA_PORT));

         Print("Unbinding 'Live' socket on port " + IntegerToString(LIVE_PORT) + "..");
         liveSocket.unbind(StringFormat("tcp://%s:%d", HOST, LIVE_PORT));

         Print("Unbinding 'Streaming' socket on port " + IntegerToString(STR_PORT) + "...");
         streamSocket.unbind(StringFormat("tcp://%s:%d", HOST, STR_PORT));

         //-- Shutdown ZeroMQ Context
         context.shutdown();
         context.destroy(0);

         EventKillTimer();

     }
  }

//+------------------------------------------------------------------+
//| Expert timer function                                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   run();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int run()
  {
//-- datetime init
   tm = TimeTradeServer();
//-- var request initialization
   ZmqMsg request;
//-- Get request from client via System socket. Wait for next request from client
   sysSocket.recv(request, true);

//-- Request received
   if(request.size() > 0)
      RequestHandler(request); // Pull request to RequestHandler().

//-- Push last candle to liveSocket.
   if(liveData)
      PushLastCandle();

   return(1);
  }

//+------------------------------------------------------------------+
//| Request handler                                                  |
//+------------------------------------------------------------------+
void RequestHandler(ZmqMsg &request)
  {
//-- Variable declaration.
   CJAVal message;

   ResetLastError();
//-- Get data from reguest
   string msg = request.getData();

//-- Debugging flag
   if(debug)
      Print("Processing:" + msg);

//-- Deserialize msg to CJAVal array
   if(!message.Deserialize(msg))
     {
      ActionDoneOrError(65537, __FUNCTION__);
      Alert("Deserialization Error");
      ExpertRemove();
     }
//-- Send response to System socket that request was received.
//-- Some historical data requests can take a lot of time.
   InformClientSocket(sysSocket, "OK");

//-- Process action command
   string action = message["action"].ToStr();

//--- Search element position
   int iAction = actions.SearchLinear(action);
   if(debug)
      Print("action ,", action, ",iAction ", iAction);

   switch(iAction)
     {
      case _ACCOUNT:
         GetAccountInfo();
         break;
      case _BALANCE:
         GetBalanceInfo();
         break;
      case _POSITIONS:
         GetPositions(message);
         break;
      case _ORDERS:
         GetOrders(message);
         break;
      case _HISTORY:
         HistoryInfo(message);
         break;
      case _TRADE:
         TradingModule(message);
         break;
      default:
         ActionDoneOrError(65538, __FUNCTION__);
         break;
     }
  }

//+------------------------------------------------------------------+
//|            Push last candle to liveSocket                                                      |
//+------------------------------------------------------------------+
void PushLastCandle()
  {
   CJAVal candle, last;
   string symbol = _symbol;  // symbol from request

// Check if terminal connected to market
   if(TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      datetime thisBar = (datetime)SeriesInfoInteger(symbol, periodTF, SERIES_LASTBAR_DATE);
      if(lastBar != thisBar)
        {
         MqlRates rates[1];

         if(CopyRates(symbol, periodTF, 1, 1, rates) != 1)
            Print((string) "errorrrrr", symbol);
         candle[0] = (long)rates[0].time;
         candle[1] = (double)rates[0].open;
         candle[2] = (double)rates[0].high;
         candle[3] = (double)rates[0].low;
         candle[4] = (double)rates[0].close;
         candle[5] = (double)rates[0].tick_volume;
         // skip sending data on script init when lastBar == 0
         if(lastBar != 0)
           {
            last["status"] = (string) "CONNECTED";
            last["data"].Set(candle);
            string t = last.Serialize();
            //ram if(debug) Print(t);
            InformClientSocket(liveSocket, t);
           }

         lastBar = thisBar;
        }
      connectedFlag = true;
     }
//If disconnected from market
   else
     {
      // send disconnect message only once
      if(connectedFlag)
        {
         last["status"] = (string) "DISCONNECTED";
         string t = last.Serialize();
         if(debug)
            Print(t);
         InformClientSocket(liveSocket, t);
         connectedFlag = false;
        }
     }
  }

//+------------------------------------------------------------------+
//| Account information                                              |
//+------------------------------------------------------------------+
void GetAccountInfo()
  {
   CJAVal info;

   info["error"] = false;
   info["broker"] = AccountInfoString(ACCOUNT_COMPANY);
   info["currency"] = AccountInfoString(ACCOUNT_CURRENCY);
   info["server"] = AccountInfoString(ACCOUNT_SERVER);
   info["trading_allowed"] = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   info["bot_trading"] = AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
   info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
   info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
   info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   info["margin_level"] = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   info["time"] = string(tm);

   string t = info.Serialize();
   if(debug)
      Print(__FUNCTION__, t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Balance information                                              |
//+------------------------------------------------------------------+
void GetBalanceInfo()
  {
   CJAVal info;
   info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
   info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
   info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
   info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   string t = info.Serialize();
//if(debug) Print(t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Fetch positions information                               |
//+------------------------------------------------------------------+
void GetPositions(CJAVal &dataObject)
  {
   CPositionInfo myposition;
   CJAVal data, position;

// Get positions
   int positionsTotal = PositionsTotal();
// Create empty array if no positions
   if(!positionsTotal)
      data["positions"].Add(position);
// Go through positions in a loop
   for(int i = 0; i < positionsTotal; i++)
     {
      ResetLastError();

      if(myposition.SelectByIndex(i))
        {
         position["id"] = PositionGetInteger(POSITION_IDENTIFIER);
         position["magic"] = PositionGetInteger(POSITION_MAGIC);
         position["symbol"] = PositionGetString(POSITION_SYMBOL);
         position["type"] = EnumToString(ENUM_POSITION_TYPE(PositionGetInteger(POSITION_TYPE)));
         position["time_setup"] = PositionGetInteger(POSITION_TIME);
         position["open"] = PositionGetDouble(POSITION_PRICE_OPEN);
         position["stoploss"] = PositionGetDouble(POSITION_SL);
         position["takeprofit"] = PositionGetDouble(POSITION_TP);
         position["volume"] = PositionGetDouble(POSITION_VOLUME);

         data["error"] = (bool)false;
         data["positions"].Add(position);
        }
      // Error handling
      else
         ActionDoneOrError(ERR_TRADE_POSITION_NOT_FOUND, __FUNCTION__);
     }

   string t = data.Serialize();
   if(debug)
      Print(__FUNCTION__, t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Fetch orders information                               |
//+------------------------------------------------------------------+
void GetOrders(CJAVal &dataObject)
  {
   ResetLastError();

   COrderInfo myorder;
   CJAVal data, order;

// Get orders
   if(HistorySelect(0, TimeCurrent()))
     {
      int ordersTotal = OrdersTotal();
      // Create empty array if no orders
      if(!ordersTotal)
        {
         data["error"] = (bool)false;
         data["orders"].Add(order);
        }

      for(int i = 0; i < ordersTotal; i++)
        {
         if(myorder.Select(OrderGetTicket(i)))
           {
            order["id"] = (string)myorder.Ticket();
            order["magic"] = OrderGetInteger(ORDER_MAGIC);
            order["symbol"] = OrderGetString(ORDER_SYMBOL);
            order["type"] = EnumToString(ENUM_ORDER_TYPE(OrderGetInteger(ORDER_TYPE)));
            order["time_setup"] = OrderGetInteger(ORDER_TIME_SETUP);
            order["open"] = OrderGetDouble(ORDER_PRICE_OPEN);
            order["stoploss"] = OrderGetDouble(ORDER_SL);
            order["takeprofit"] = OrderGetDouble(ORDER_TP);
            order["volume"] = OrderGetDouble(ORDER_VOLUME_INITIAL);

            data["error"] = (bool)false;
            data["orders"].Add(order);
           }
         // Error handling
         else
            ActionDoneOrError(ERR_TRADE_ORDER_NOT_FOUND, __FUNCTION__);
        }
     }

   string t = data.Serialize();
   if(debug)
      Print(__FUNCTION__, t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Get historical data                                              |
//+------------------------------------------------------------------+
void HistoryInfo(CJAVal &dataObject)
  {
//-- Process actionType sub-command
   string actionType = dataObject["actionType"].ToStr();

//--- Search element position
   int iActionType = actionTypes.SearchLinear(actionType);
   if(debug)
      Print("actionType ,", actionType, " iActionType ,", iActionType);
   switch(iActionType)
     {
      case _DATA:
         GetHistoryData(dataObject);
         break;
      case _TRADES:
         GetHistoryTrades();
         break;
      default:
         // Error wrong action type
         ActionDoneOrError(65538, __FUNCTION__);
         break;
     }
   return;
  }
//+------------------------------------------------------------------+
//| Get data history                                                 |
//+------------------------------------------------------------------+
void GetHistoryData(CJAVal &dataObject)
  {
   CJAVal c, d;
   MqlRates r[];

   int copied;
   string symbol = dataObject["symbol"].ToStr();
//ram
   _symbol = symbol;

   ENUM_TIMEFRAMES period = GetTimeframe(dataObject["chartTF"].ToStr());
   periodTF = period;
   datetime fromDate = (datetime)dataObject["fromDate"].ToInt();
   datetime toDate = TimeCurrent();
   if(dataObject["toDate"].ToInt() != NULL)
      toDate = (datetime)dataObject["toDate"].ToInt();

   if(debug)
     {
      Print("Fetching HISTORY");
      Print("1) Symbol:" + symbol);
      Print("2) Timeframe:" + EnumToString(period));
      Print("3) Date from:" + TimeToString(fromDate));
      if(dataObject["toDate"].ToInt() != NULL)
         Print("4) Date to:" + TimeToString(toDate));
     }

   copied = CopyRates(symbol, period, fromDate, toDate, r);
   if(copied)
     {
      for(int i = 0; i < copied; i++)
        {
         c[i][0] = (long)r[i].time;
         c[i][1] = (double)r[i].open;
         c[i][2] = (double)r[i].high;
         c[i][3] = (double)r[i].low;
         c[i][4] = (double)r[i].close;
         c[i][5] = (double)r[i].tick_volume;
        }
      d["data"].Set(c);
     }
   else
     {
      d["data"].Add(c);
     }

   string t = d.Serialize();
//if(debug) Print(t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Get trades history                                               |
//+------------------------------------------------------------------+
void GetHistoryTrades()
  {
   CDealInfo tradeInfo;
   CJAVal trades, data;

   if(HistorySelect(0, TimeCurrent()))
     {
      // Get total deals in history
      int total = HistoryDealsTotal();
      ulong ticket;  // deal ticket

      for(int i = 0; i < total; i++)
        {
         if((ticket = HistoryDealGetTicket(i)) > 0)
           {
            tradeInfo.Ticket(ticket);
            data["ticket"] = (long)tradeInfo.Ticket();
            data["time"] = (long)tradeInfo.Time();
            data["price"] = (double)tradeInfo.Price();
            data["volume"] = (double)tradeInfo.Volume();
            data["symbol"] = (string)tradeInfo.Symbol();
            data["type"] = (string)tradeInfo.TypeDescription();
            data["entry"] = (long)tradeInfo.Entry();
            data["profit"] = (double)tradeInfo.Profit();

            trades["trades"].Add(data);
           }
        }
     }
   else
     {
      trades["trades"].Add(data);
     }

   string t = trades.Serialize();
//if(debug) Print(t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Trading module                                                   |
//+------------------------------------------------------------------+
void TradingModule(CJAVal &dataObject)
  {
//-- Initialization
   ResetLastError();
   CTrade trade;
   ENUM_ORDER_TYPE orderType;

//-- Setting the magic number
   magicNumber = dataObject["magic"].ToInt();
   trade.SetExpertMagicNumber(magicNumber);
   
//-- Order construction
   string symbol = dataObject["symbol"].ToStr();
   int idNumber = dataObject["id"].ToInt();
   double volume = dataObject["volume"].ToDbl();
   double SL = dataObject["stoploss"].ToDbl();
   double TP = dataObject["takeprofit"].ToDbl();
   double price = NormalizeDouble(dataObject["price"].ToDbl(), _Digits);
   double deviation = dataObject["deviation"].ToDbl();
   string comment = dataObject["comment"].ToStr();

// Order expiration section
   ENUM_ORDER_TYPE_TIME type_time = ORDER_TIME_GTC;
   datetime expiration = 0;
   if(dataObject["expiration"].ToInt() != 0)
     {
      type_time = ORDER_TIME_SPECIFIED;
      expiration = dataObject["expiration"].ToInt();
     }

//-- Process actionType sub-command
   string actionType = dataObject["actionType"].ToStr();

//--- Search element position
   int iActionType = actionTypes.SearchLinear(actionType);
   if(debug)
      Print("actionType ,", actionType, " iActionType ,", iActionType);

   switch(iActionType)
     {
      case _ORDER_TYPE_BUY:
         price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         orderType = ORDER_TYPE_BUY;
         if(trade.PositionOpen(symbol, orderType, volume, price, SL, TP, comment))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_TYPE_SELL:
         price = SymbolInfoDouble(symbol, SYMBOL_BID);
         orderType = ORDER_TYPE_SELL;
         if(trade.PositionOpen(symbol, orderType, volume, price, SL, TP, comment))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_TYPE_BUY_LIMIT:
         if(trade.BuyLimit(volume, price, symbol, SL, TP, type_time, expiration, comment))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_TYPE_SELL_LIMIT:
         if(trade.SellLimit(volume, price, symbol, SL, TP, type_time, expiration, comment))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_TYPE_BUY_STOP:
         if(trade.BuyStop(volume, price, symbol, SL, TP, type_time, expiration, comment))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_TYPE_SELL_STOP:
         if(trade.SellStop(volume, price, symbol, SL, TP, type_time, expiration, comment))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _POSITION_MODIFY:
         if(trade.PositionModify(idNumber, SL, TP))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _POSITION_PARTIAL:
         if(trade.PositionClosePartial(idNumber, volume))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _POSITION_CLOSE_ID:
         if(trade.PositionClose(idNumber))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _POSITION_CLOSE_SYMBOL:
         if(trade.PositionClose(symbol))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_MODIFY:
         if(trade.OrderModify(idNumber, price, SL, TP, type_time, expiration))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      case _ORDER_CANCEL:
         if(trade.OrderDelete(idNumber))
           {
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
           }
         break;
      default:
         ActionDoneOrError(65538, __FUNCTION__);
         break;
     }

// This part of the code runs if order was not completed
   OrderDoneOrError(true, __FUNCTION__, trade);
  }

//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   ENUM_TRADE_TRANSACTION_TYPE trans_type = trans.type;
   switch(trans.type)
     {
      // case  TRADE_TRANSACTION_POSITION: {}  break;
      // case  TRADE_TRANSACTION_DEAL_ADD: {}  break;
      case TRADE_TRANSACTION_REQUEST:
        {
         CJAVal data, req, res;

         req["action"] = EnumToString(request.action);               // Trade operation type
         req["magic"] = (int) request.magic;                         // Expert Advisor ID (magic number)
         req["order"] = (int)request.order;                          // Order ticket
         req["symbol"] = (string)request.symbol;                     // Trade symbol
         req["volume"] = (double)request.volume;                     // Requested volume for a deal in lots
         req["price"] = (double)request.price;                       // Price
         req["stoplimit"] = (double)request.stoplimit;               // StopLimit level of the order
         req["sl"] = (double)request.sl;                             // Stop Loss level of the order
         req["tp"] = (double)request.tp;                             // Take Profit level of the order
         req["deviation"] = (int)request.deviation;                  // Maximal possible deviation from the requested price
         req["type"] = EnumToString(request.type);                   // Order type
         req["type_filling"] = EnumToString(request.type_filling);   // Order execution type
         req["type_time"] = EnumToString(request.type_time);         // Order expiration type
         req["expiration"] = (int)request.expiration;                // Order expiration time (for the orders of ORDER_TIME_SPECIFIED type)
         req["comment"] = (string)request.comment;                   // Order comment
         req["position"] = (int)request.position;                    // Position ticket
         req["position_by"] = (int)request.position_by;              // The ticket of an opposite position

         res["retcode"] = (int)result.retcode;                       // Operation return code
         res["result"] = (string)GetRetcodeID(result.retcode);
         res["deal"] = (int)result.deal;                             // Deal ticket, if it is performed
         res["order"] = (int)result.order;                           // Order ticket, if it is placed
         res["volume"] = (double)result.volume;                      // Deal volume, confirmed by broker
         res["price"] = (double)result.price;                        // Deal price, confirmed by broker
         res["bid"] = (double)result.bid;                            // Current Bid price
         res["ask"] = (double)result.ask;                            // Current Ask price
         res["comment"] = (string)result.comment;                    // Broker comment to operation (by default it is filled by description of trade server return code)
         res["request_id"] = (int)result.request_id;                 // Request ID set by the terminal during the dispatch
         res["retcode_external"] = (int)result.retcode_external;     // Return code of an external trading system

         data["request"].Set(req);
         data["result"].Set(res);

         string t = data.Serialize();
         if(debug)
            Print(__FUNCTION__, t);
         InformClientSocket(streamSocket, t);
        }
      break;
      default:
        {
        } break;
     }
  }


//+------------------------------------------------------------------+
//| Convert chart timeframe from string to enum                      |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetTimeframe(string chartTF)
  {
   ENUM_TIMEFRAMES tf =PERIOD_M1;// default
//--- Search element position
   int iTimeFrame = timeFrames.SearchLinear(chartTF);
   if(debug)
      Print("timeFrame ,", chartTF, ",iTimeFrame ,", iTimeFrame);

   switch(iTimeFrame)
     {
      case _M1:
         tf = PERIOD_M1;
         break;
      case _M2:
         tf = PERIOD_M2;
         break;
      case _M3:
         tf = PERIOD_M3;
         break;
      case _M4:
         tf = PERIOD_M4;
         break;
      case _M5:
         tf = PERIOD_M5;
         break;
      case _M6:
         tf = PERIOD_M6;
         break;
      case _M10:
         tf = PERIOD_M10;
         break;
      case _M12:
         tf = PERIOD_M12;
         break;
      case _M15:
         tf = PERIOD_M15;
         break;
      case _M20:
         tf = PERIOD_M20;
         break;
      case _M30:
         tf = PERIOD_M30;
         break;
      case _H1:
         tf = PERIOD_H1;
         break;
      case _H2:
         tf = PERIOD_H2;
         break;
      case _H3:
         tf = PERIOD_H3;
         break;
      case _H4:
         tf = PERIOD_H4;
         break;
      case _H6:
         tf = PERIOD_H6;
         break;
      case _H8:
         tf = PERIOD_H8;
         break;
      case _H12:
         tf = PERIOD_H12;
         break;
      case _D1:
         tf = PERIOD_D1;
         break;
      case _W1:
         tf = PERIOD_W1;
         break;
      case _MN1:
         tf = PERIOD_MN1;
         break;
      default:
         ActionDoneOrError(65538, __FUNCTION__);
         break;
     }
   return (tf);
  }

//+------------------------------------------------------------------+
//| Trade confirmation                                               |
//+------------------------------------------------------------------+
void OrderDoneOrError(bool error, string funcName, CTrade &trade)
  {
   CJAVal conf;

   conf["error"] = (bool)error;
   conf["retcode"] = (int)trade.ResultRetcode();
   conf["description"] = (string)GetRetcodeID(trade.ResultRetcode());
   conf["deal"]=(int) trade.ResultDeal();
   conf["order"] = (int)trade.ResultOrder();
   conf["volume"] = (double)trade.ResultVolume();
   conf["price"] = (double)trade.ResultPrice();
   conf["bid"] = (double)trade.ResultBid();
   conf["ask"] = (double)trade.ResultAsk();
   conf["function"] = (string)funcName;

   string t = conf.Serialize();
   if(debug)
      Print(__FUNCTION__, t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Action confirmation                                              |
//+------------------------------------------------------------------+
void ActionDoneOrError(int lastError, string funcName)
  {
   CJAVal conf;

   conf["error"] = (bool)true;
   if(lastError == 0)
      conf["error"] = (bool)false;

   conf["lastError"] = (string)lastError;
   conf["description"] = GetErrorID(lastError);
   conf["function"] = (string)funcName;

   string t = conf.Serialize();
   if(debug)
      Print(__FUNCTION__, t);
   InformClientSocket(dataSocket, t);
  }

//+------------------------------------------------------------------+
//| Inform Client via socket                                         |
//+------------------------------------------------------------------+
void InformClientSocket(Socket &workingSocket, string replyMessage)
  {
// non-blocking
   workingSocket.send(replyMessage, true);
// TODO: Array out of range error
   ResetLastError();
  }

//+------------------------------------------------------------------+
//| Get retcode message by retcode id                                |
//+------------------------------------------------------------------+
string GetRetcodeID(int retcode)
  {
   switch(retcode)
     {
      case 10004:
         return ("TRADE_RETCODE_REQUOTE");
         break;
      case 10006:
         return ("TRADE_RETCODE_REJECT");
         break;
      case 10007:
         return ("TRADE_RETCODE_CANCEL");
         break;
      case 10008:
         return ("TRADE_RETCODE_PLACED");
         break;
      case 10009:
         return ("TRADE_RETCODE_DONE");
         break;
      case 10010:
         return ("TRADE_RETCODE_DONE_PARTIAL");
         break;
      case 10011:
         return ("TRADE_RETCODE_ERROR");
         break;
      case 10012:
         return ("TRADE_RETCODE_TIMEOUT");
         break;
      case 10013:
         return ("TRADE_RETCODE_INVALID");
         break;
      case 10014:
         return ("TRADE_RETCODE_INVALID_VOLUME");
         break;
      case 10015:
         return ("TRADE_RETCODE_INVALID_PRICE");
         break;
      case 10016:
         return ("TRADE_RETCODE_INVALID_STOPS");
         break;
      case 10017:
         return ("TRADE_RETCODE_TRADE_DISABLED");
         break;
      case 10018:
         return ("TRADE_RETCODE_MARKET_CLOSED");
         break;
      case 10019:
         return ("TRADE_RETCODE_NO_MONEY");
         break;
      case 10020:
         return ("TRADE_RETCODE_PRICE_CHANGED");
         break;
      case 10021:
         return ("TRADE_RETCODE_PRICE_OFF");
         break;
      case 10022:
         return ("TRADE_RETCODE_INVALID_EXPIRATION");
         break;
      case 10023:
         return ("TRADE_RETCODE_ORDER_CHANGED");
         break;
      case 10024:
         return ("TRADE_RETCODE_TOO_MANY_REQUESTS");
         break;
      case 10025:
         return ("TRADE_RETCODE_NO_CHANGES");
         break;
      case 10026:
         return ("TRADE_RETCODE_SERVER_DISABLES_AT");
         break;
      case 10027:
         return ("TRADE_RETCODE_CLIENT_DISABLES_AT");
         break;
      case 10028:
         return ("TRADE_RETCODE_LOCKED");
         break;
      case 10029:
         return ("TRADE_RETCODE_FROZEN");
         break;
      case 10030:
         return ("TRADE_RETCODE_INVALID_FILL");
         break;
      case 10031:
         return ("TRADE_RETCODE_CONNECTION");
         break;
      case 10032:
         return ("TRADE_RETCODE_ONLY_REAL");
         break;
      case 10033:
         return ("TRADE_RETCODE_LIMIT_ORDERS");
         break;
      case 10034:
         return ("TRADE_RETCODE_LIMIT_VOLUME");
         break;
      case 10035:
         return ("TRADE_RETCODE_INVALID_ORDER");
         break;
      case 10036:
         return ("TRADE_RETCODE_POSITION_CLOSED");
         break;
      case 10038:
         return ("TRADE_RETCODE_INVALID_CLOSE_VOLUME");
         break;
      case 10039:
         return ("TRADE_RETCODE_CLOSE_ORDER_EXIST");
         break;
      case 10040:
         return ("TRADE_RETCODE_LIMIT_POSITIONS");
         break;
      case 10041:
         return ("TRADE_RETCODE_REJECT_CANCEL");
         break;
      case 10042:
         return ("TRADE_RETCODE_LONG_ONLY");
         break;
      case 10043:
         return ("TRADE_RETCODE_SHORT_ONLY");
         break;
      case 10044:
         return ("TRADE_RETCODE_CLOSE_ONLY");
         break;

      default:
         return ("TRADE_RETCODE_UNKNOWN=" + IntegerToString(retcode));
         break;
     }
  }

//+------------------------------------------------------------------+
//| Get error message by error id                                    |
//+------------------------------------------------------------------+
string GetErrorID(int error)
  {
   switch(error)
     {
      case 0:
         return ("ERR_SUCCESS");
         break;
      case 4301:
         return ("ERR_MARKET_UNKNOWN_SYMBOL");
         break;
      case 4303:
         return ("ERR_MARKET_WRONG_PROPERTY");
         break;
      case 4752:
         return ("ERR_TRADE_DISABLED");
         break;
      case 4753:
         return ("ERR_TRADE_POSITION_NOT_FOUND");
         break;
      case 4754:
         return ("ERR_TRADE_ORDER_NOT_FOUND");
         break;
      // Custom errors
      case 65537:
         return ("ERR_DESERIALIZATION");
         break;
      case 65538:
         return ("ERR_WRONG_ACTION");
         break;
      case 65539:
         return ("ERR_WRONG_ACTION_TYPE");
         break;

      default:
         return ("ERR_CODE_UNKNOWN=" + IntegerToString(error));
         break;
     }
  }

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

import '../models/candle.dart' as model;


// ⚠️ KUMBUKA: Token hii ipo wazi (hardcoded) kwa ombi la mtumiaji la
// "acha palepale kwa sasa". Hatari ya usalama niliyoeleza awali
// (yeyote mwenye ufikiaji wa code anaweza kuitumia kuingia kwenye
// akaunti yako ya Deriv) bado ipo - itafutwa (revoke) na kuhamishiwa
// kwenye --dart-define/.env pale utakapokuwa tayari.
const String derivToken =
    "pat_e4a19bbef8ce170aa1d9d57682be9d2877a88ff77d061fc9ddea455845a81850";

// 🚨🚨🚨 CHANZO KIKUU CHA "InvalidToken" TULICHOKIGUNDUA: '1089' ni
// app_id ya UMMA/MFANO ya Deriv (inatumika kwenye mifano YOTE ya
// nyaraka zao rasmi - "app_id 1089 is for testing, create your own
// app_id"). Kwa matumizi ya kudumu/uzalishaji na token ya kibinafsi,
// SAJILI APP_ID YAKO MWENYEWE kupitia https://api.deriv.com (au
// developers.deriv.com/docs/app-registration - "Register
// Application"), kisha BADILISHA NAMBA HII kwa app_id yako halisi.
//
// FIX (aina ya data): 'derivAppId' sasa ni String (si int) - Deriv
// imebadilisha muundo wa App ID kwa usajili mpya (sasa ni
// herufi+namba mchanganyiko, si namba tupu kama '1089' ya zamani).
const String derivAppId = "33SNU6dEw3F7xVhyEHxz3"; // 🚨 BADILISHA HII na App ID yako mwenyewe

// 🚨🚨🚨 ONGEZO JIPYA MUHIMU SANA: umegundulika kwamba akaunti hii
// inatumia bidhaa ya "Options" (mpya) ya Deriv - ambayo ina API TOFAUTI
// KABISA na "Classic" (Multipliers/CFDs) tuliyokuwa tukiitumia awali.
// Options API HAIHITAJI ujumbe wa "authorize" kabisa - badala yake
// inahitaji hatua ya REST kwanza (kupata "OTP" - One Time Password)
// ikitumia Account ID + Token, KISHA kuunganisha kwa WebSocket URL
// maalum inayorudishwa (yenye OTP ndani yake tayari).
const String derivAccountId = "ROT91878830"; // Account ID yako


// FIX / MABORESHO: awali kulikuwa tu na m1, h1, h4, d1, w1, mn.
// Kwa mfumo kamili wa TOP-DOWN + BACKTEST unaohitajika (mwaka -> 
// mwezi -> wiki -> siku -> saa 4 -> saa 1 -> nusu saa -> dakika 15),
// ziliongezwa: m15, m30 (zinaombwa moja kwa moja kwa Deriv -
// granularity halisi), na y1 (mwaka - inajengwa humu ndani kutoka
// D1 kama vile w1/mn, kwa sababu Deriv haina granularity ya mwaka).
enum TF {
  m1,
  m15,
  m30,
  h1,
  h4,
  d1,
  w1,
  mn,
  y1,
}

// FIX (bug ya compile): enum hii ilikuwa imetangazwa NDANI ya class
// DerivService - Dart HAIRUHUSU enum ndani ya class (tofauti na baadhi
// ya lugha nyingine). Imehamishwa hapa kama top-level enum, nje ya
// class yoyote.
enum _CalendarUnit { week, month, year }

// ONGEZO JIPYA: rekodi ya "live subscription" moja (jina halisi la
// alama - herufi sahihi kama Deriv inavyolitambua - na timeframe) -
// inatumika kurejesha (resubscribe) candle streams baada ya reconnect.
class _LiveSub {
  final String symbolRaw;
  final TF tf;

  const _LiveSub(this.symbolRaw, this.tf);
}


class DerivService {

  static final DerivService instance =
      DerivService._internal();


  DerivService._internal();


  factory DerivService() => instance;



  WebSocketChannel? _channel;

  StreamSubscription? _sub;


  bool _connected = false;

  bool _auth = false;

  bool _connecting = false;



  Timer? _keepAlive;



  final Map<String, Map<TF, List<model.Candle>>> _data = {};

  final Set<String> _subscribed = {};

  // 🚨 ONGEZO JIPYA (fix ya bug hatari): orodha ya "live subscriptions"
  // (jina halisi la alama + timeframe) zinazohitaji KUREJESHWA
  // (resubscribe) baada ya reconnect - angalia maelezo marefu kwenye
  // _reconnect()/_handle() kuhusu kwa nini hii ilikuwa ikikosekana na
  // kusababisha injini "kufa kimya kimya" baada ya muunganiko wowote
  // kukatika.
  final List<_LiveSub> _liveSubs = [];

  final List<String> _marketPairs = [];

  // ONGEZO JIPYA: ramani ya "jina lililosawazishwa (UPPERCASE) -> jina
  // halisi kama Deriv inavyolitambua" - angalia maelezo marefu kwenye
  // _handle() sehemu ya "active_symbols".
  final Map<String, String> _originalCasing = {};

  /// Inarudisha jina HALISI la alama (herufi sahihi kama Deriv
  /// inavyolitambua, mf. "frxEURUSD") kutoka jina lolote la ingizo
  /// (UPPERCASE au vinginevyo). Kama halijapatikana kwenye ramani
  /// (mf. 'getMarketPairs()' haijawahi kuitwa), inarudisha ingizo
  /// lililopewa bila kubadilika - angalau si mbaya zaidi ya awali.
  ///
  /// MUHIMU: ITUMIKE KABLA ya kuita placeTrade() kwa TRADE HALISI -
  /// vinginevyo jina la UPPERCASE (kutoka UI/signal payload) litatumwa
  /// moja kwa moja kwa Deriv, na litakataliwa/kutokutambuliwa kwa
  /// alama zenye herufi mchanganyiko kiasili (FRX*, CRY*, stpRNG*).
  String resolveOriginalCasing(String anyCasing) {
    final key = normalizeSymbol(anyCasing);
    return _originalCasing[key] ?? anyCasing;
  }



  final StreamController<Map<String,dynamic>> _stream =
      StreamController.broadcast();



  // compatibility
  Stream<Map<String,dynamic>> get stream =>
      _stream.stream;


  Stream<Map<String,dynamic>> get wsStream =>
      _stream.stream;



  bool get isConnected =>
      _connected && _auth;



  String? _token;

  // FIX: kihesabu cha req_id kwa ajili ya kuoanisha ombi/majibu ya WS
  // moja kwa moja (muhimu kwa _request() na fetchHistoricalCandles()
  // hapa chini - vinginevyo majibu ya maombi mengi yanayofanana
  // yanaweza kuchanganyikiwa).
  int _reqIdCounter = 0;

  // =====================================================
  // CONNECT
  // =====================================================

  Future<void> connect([String? token]) async {
    if (_connected || _connecting) return;

    _connecting = true;

    try {
      _token = token ?? derivToken;

      // 🚨🚨🚨 MABADILIKO MAKUBWA (Options API - OTP flow): tofauti na
      // API ya "Classic" (ambayo tulikuwa tukiiunganisha moja kwa moja
      // kwa WebSocket kisha kutuma ujumbe wa "authorize"), Options API
      // inahitaji HATUA YA REST KWANZA - kuomba "OTP" (One Time
      // Password) ikitumia Account ID + Token, KISHA kuunganisha kwa
      // WebSocket URL MAALUM inayorudishwa (OTP tayari imo ndani ya
      // URL hiyo - HAKUNA ujumbe wa "authorize" unaohitajika tena).
      print("🔌 Kupata OTP URL kutoka Deriv Options API...");

      final otpUrl = await _fetchOtpUrl();

      if (otpUrl == null) {
        print(
          "❌ Imeshindwa kupata OTP URL - muunganiko hauwezekani. "
          "Angalia Account ID, App ID, na Token yako.",
        );
        _connected = false;
        _auth = false;
        _connecting = false;
        _reconnect();
        return;
      }

      final uri = Uri.parse(otpUrl);

      print("🔌 Connecting Deriv (Options API, OTP)...");

      _channel = WebSocketChannel.connect(uri);

      _sub = _channel!.stream.listen(

        (message){


          try {


            final data =
                jsonDecode(message);



            if(data is Map<String,dynamic>){

              _handle(data);

              _stream.add(data);

            }


          }catch(e){

            print(
              "❌ Decode error $e"
            );

          }



        },


        onDone: (){

          _reconnect();

        },


        onError:(e){

          print(
            "❌ WS ERROR $e"
          );

          _reconnect();

        },


      );



      _connected=true;

      // 🚨 MABADILIKO MAKUBWA: Options API HAIHITAJI ujumbe wa
      // "authorize" - OTP kwenye URL YENYEWE tayari imethibitisha
      // kikao (session) KABLA hata hatujaunganisha. Kwa hiyo
      // tunaweka '_auth=true' MARA MOJA hapa (si kusubiri jibu la
      // "authorize" kama ilivyokuwa kwenye API ya Classic - jibu
      // hilo HALIWAHI kutumwa kwenye Options API kabisa).
      _auth = true;

      print("✅ Deriv Authorized (Options API - OTP)");

      // FIX: kazi zilizokuwa zikitokea ndani ya '_handle()' sehemu ya
      // "authorize" (kutuma active_symbols, kurejesha live
      // subscriptions baada ya reconnect) sasa zinaitwa MOJA KWA MOJA
      // hapa - mara tu muunganiko wa Options API unapofanikiwa.
      _send({
        "active_symbols": "brief",
      });

      if (_liveSubs.isNotEmpty) {
        print(
          "🔁 Inarejesha (resubscribe) live subscriptions "
          "${_liveSubs.length} baada ya muunganiko...",
        );

        final toRestore = List<_LiveSub>.from(_liveSubs);

        for (final sub in toRestore) {
          subscribeCandles(
            sub.symbolRaw,
            tf: sub.tf,
            live: true,
            force: true,
          );
        }
      }

      _startKeepAlive();



    }catch(e){


      print(
        "❌ CONNECT FAILED $e"
      );


      _connected=false;

      _auth=false;



    }finally{

      _connecting=false;

    }

  }

  // =====================================================
  // FETCH OTP URL (ONGEZO JIPYA - Options API)
  // =====================================================
  //
  // Inaomba "OTP" (One Time Password) kutoka Deriv kupitia REST
  // endpoint, ikitumia Account ID + Token kama uthibitisho. Jibu
  // lina URL KAMILI ya WebSocket (yenye OTP ndani yake) - tunatumia
  // URL hiyo moja kwa moja kuunganisha, bila hatua nyingine yoyote
  // ya uthibitisho.
  Future<String?> _fetchOtpUrl() async {
    try {
      final uri = Uri.parse(
        "https://api.derivws.com/trading/v1/options/accounts/"
        "$derivAccountId/otp",
      );

      final response = await http.post(
        uri,
        headers: {
          "Deriv-App-ID": derivAppId,
          "Authorization": "Bearer ${_token ?? derivToken}",
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final url = data["data"]?["url"] as String?;

        if (url == null) {
          print(
            "❌ OTP response haina 'url' inayotarajiwa: ${response.body}",
          );
          return null;
        }

        print("✅ OTP URL imepatikana kikamilifu.");

        return url;
      } else {
        print(
          "❌ OTP fetch imeshindwa: HTTP ${response.statusCode} - "
          "${response.body}",
        );
        return null;
      }
    } catch (e) {
      print("❌ OTP fetch error: $e");
      return null;
    }
  }





  // =====================================================
  // KEEP ALIVE
  // =====================================================


  void _startKeepAlive(){


    _keepAlive?.cancel();



    _keepAlive =
        Timer.periodic(
          const Duration(seconds:20),
          (_) {


            if(_connected){

              _send({
                "ping":1
              });

            }


          },
        );


  }
  // =====================================================
  // HANDLE SERVER RESPONSE
  // =====================================================


  void _handle(Map<String,dynamic> data){


    final type = data["msg_type"];


    // FIX: hapo awali hakuna kilichofanywa na majibu ya "error" kutoka
    // Deriv (mf. token batili, symbol batili, parameter zisizo sahihi,
    // duration inayokosekana kwenye proposal). Yalikuwa yakipotea
    // kimya kimya, hivyo makosa yalikuwa magumu kutambua/ku-debug.
    if (type == "error") {
      final err = data["error"];
      print(
        "❌ DERIV ERROR (${err?["code"]}): ${err?["message"]} "
        "| req_id=${data["req_id"]} echo=${data["echo_req"]}",
      );
    }



    // ================= AUTH =================

    // KUMBUKA (baada ya mabadiliko ya Options API/OTP): block hii
    // (na yote ndani yake) SASA NI DEAD CODE kwa mtiririko wa kawaida
    // - Options API HAITUMI ujumbe wa "authorize" kabisa (uthibitisho
    // unafanyika kupitia OTP kwenye URL ya WebSocket YENYEWE, kabla
    // hata ya kuunganisha - angalia connect()/_fetchOtpUrl()).
    // Nimeibakiza hapa BILA kuiondoa - kwa usalama, endapo siku moja
    // itahitajika kurudi kwenye API ya "Classic" (Multipliers/CFDs),
    // au endapo Deriv itatuma ujumbe wa aina hii kwa sababu nyingine
    // isiyotarajiwa.
    if(type=="authorize"){

      // 🚨🚨🚨 FIX YA BUG MUHIMU ZAIDI TULIYOIPATA LEO: awali hapa
      // tulikuwa tukiweka '_auth=true' na kuchapisha "✅ Deriv
      // Authorized" MARA TU 'msg_type=="authorize"' ilipofika - BILA
      // KUANGALIA kama jibu hilo hilo lina 'error' field ndani yake!
      //
      // Tuligundua (kupitia uchunguzi wa balance) kwamba Deriv
      // INARUDISHA 'msg_type' ILE ILE ya ombi (mf. "balance",
      // "authorize") HATA KAMA kuna hitilafu - hitilafu inajificha
      // KATIKA 'error' field ndani ya jibu hilo hilo, SI kwenye
      // 'msg_type: "error"' ya jumla kama tulivyodhania awali. Kwa
      // hiyo: kama TOKEN ni batili/imefutwa (revoked) - jambo
      // linalowezekana SANA endapo umekuwa ukibadilisha token mara
      // kwa mara - Deriv inarudisha 'msg_type:"authorize"' IKIWA NA
      // 'error' (mf. "InvalidToken") - na code ya AWALI ilikuwa
      // ikiiona TU 'msg_type=="authorize"' na kusherehekea mafanikio
      // ya uongo, bila kuangalia error hiyo KABISA! Hii ndiyo
      // iliyosababisha kila ombi la baadaye (balance, n.k.)
      // kushindwa kwa "AuthorizationRequired - Please log in" - kwa
      // sababu HALISI hatukuwahi ku-authorize kikamilifu.
      final authError = data["error"];

      if (authError != null) {

        _auth = false;

        print(
          "❌❌❌ AUTHORIZE IMESHINDWA: "
          "${authError["code"]} - ${authError["message"]} | "
          "ANGALIA TOKEN YAKO - inawezekana imefutwa (revoked) au si "
          "sahihi. Hakuna ombi lolote la baadaye litakalofanya kazi "
          "hadi hili litatuliwe.",
        );

        // FIX: usiendelee kutuma active_symbols/resubscribe - hazina
        // maana yoyote kama authorize halisi haikufanikiwa (zingeshindwa
        // kwa sababu ile ile).

      } else {

      _auth=true;

      print(
        "✅ Deriv Authorized"
      );

      // FIX (angalia maelezo marefu kwenye connect()): 'active_symbols'
      // sasa inatumwa HAPA - MARA TU baada ya Deriv kuthibitisha
      // authorize - badala ya kutumwa kipofu mara moja baada ya
      // kutuma 'authorize' bila kusubiri jibu. Hii inahakikisha Deriv
      // inarudisha orodha KAMILI ya alama zinazopatikana kwa akaunti
      // hii mahususi (si orodha ndogo ya default/unauthenticated).
      _send({
        "active_symbols": "brief",
      });

      // 🚨 FIX YA BUG HATARI SANA: hii ndiyo ilikuwa ikikosekana kabisa
      // - baada ya 'authorize' kuthibitika (iwe ni connect ya kwanza
      // KABISA, au RECONNECT baada ya muunganiko kukatika), tunarejesha
      // (resubscribe) candle streams ZOTE zilizokuwa 'live' kabla.
      //
      // KWA NINI HII NI MUHIMU: kabla ya fix hii, '_reconnect()'
      // ilikuwa ikiunganisha upya na Deriv na kuidhinisha (authorize)
      // upya KIKAMILIFU - lakini HAIKUWAHI kutuma tena maombi ya
      // 'ticks_history'/'subscribe' kwa alama zilizokuwa zikifuatiliwa
      // kabla ya muunganiko kukatika. Kwa Deriv, WebSocket session
      // MPYA haina KUMBUKUMBU YOYOTE ya subscriptions za session ya
      // ZAMANI - hivyo injini ilikuwa ikionekana "inafanya kazi salama"
      // (hakuna error, FORCED ANALYSIS inaendelea kuchapishwa kila
      // dakika 5) LAKINI data (H1/H4/D1/W1) ZOTE zilibaki ZIMEGANDA
      // MILELE kwenye thamani za mwisho kabla ya kukatika (au 0 kama
      // muunganiko ulikatika kabla ya data ya kwanza kufika) - kimya
      // kabisa, bila dalili yoyote wazi. Hii ndiyo iliyosababisha
      // ALAMA ZOTE (hata zile za UPPERCASE-kiasili zilizokuwa daima
      // zikifanya kazi) kuonyesha "H1=0 INSUFFICIENT" kwa pamoja baada
      // ya tukio la kukatika/kuunganisha upya lolote lile.
      //
      // Sasa: tunatumia (resend) ombi la 'ticks_history' kwa kila
      // rekodi ndani ya '_liveSubs' (jina halisi la alama + timeframe)
      // - kwa 'force:true' kuhakikisha guard ya '_subscribed' haizuii
      // ombi hili jipya kutumwa.
      if (_liveSubs.isNotEmpty) {
        print(
          "🔁 Inarejesha (resubscribe) live subscriptions ${_liveSubs.length} "
          "baada ya authorize/reconnect...",
        );

        // Nakili orodha kwanza - subscribeCandles() inaweza kuongeza
        // rekodi mpya kwenye '_liveSubs' wakati wa kuzunguka (iteration)
        // hii, jambo linaloweza kusababisha hitilafu ya "concurrent
        // modification" kama tungezunguka orodha halisi moja kwa moja.
        final toRestore = List<_LiveSub>.from(_liveSubs);

        for (final sub in toRestore) {
          subscribeCandles(
            sub.symbolRaw,
            tf: sub.tf,
            live: true,
            force: true,
          );
        }
      }

    }

    } // FIX: kufunga 'else' block iliyoongezwa (angalia mwanzo wa
      // 'if(type=="authorize")' - sasa kuna njia mbili: authError!=null
      // (kushindwa) au else (mafanikio, mantiki ya awali yote).




    // ================= ACTIVE SYMBOLS =================

    if(type=="active_symbols"){


      final list =
          data["active_symbols"];



      if(list is List){


        _marketPairs
          ..clear()
          ..addAll(
            list.map(
              (e)=>e["symbol"].toString()
            ),
          );

        // 🚨 ONGEZO JIPYA (fix ya bug hatari ya casing - safari hii kwa
        // UTEKELEZAJI WA TRADE, si kupata candles tu): server ya
        // risk management (server 2) inapokea jina la alama kutoka UI
        // likiwa TAYARI limesawazishwa (UPPERCASE, kutoka kwa
        // signals_server.dart ya server 1 - angalia maelezo marefu
        // huko). Kwa hiyo, kwa wakati trades.dart inapotaka kufungua
        // TRADE HALISI, haina tena jina sahihi la Deriv (mf.
        // "frxEURUSD" - herufi mchanganyiko) - ina TU "FRXEURUSD"
        // (UPPERCASE). Kama tungetuma hilo moja kwa moja kwa Deriv
        // kwenye ombi la 'proposal'/'buy', tungerudia BUG ILE ILE ya
        // casing tuliyoipata na kuirekebisha kwa ajili ya
        // 'ticks_history' - lakini safari hii ingeathiri UTEKELEZAJI
        // WA PESA HALISI, si uchambuzi tu.
        //
        // Sasa: ramani (map) ya "UPPERCASE -> jina halisi" inajengwa
        // hapa (chanzo cha uhakika - moja kwa moja kutoka Deriv
        // 'active_symbols'), na 'resolveOriginalCasing()' hapa chini
        // inaruhusu caller yeyote (mf. trades.dart kabla ya
        // placeTrade()) kupata jina sahihi kabla ya kutuma ombi la
        // trade halisi.
        for (final e in list) {
          final rawSymbol = e["symbol"]?.toString();
          if (rawSymbol != null && rawSymbol.isNotEmpty) {
            _originalCasing[normalizeSymbol(rawSymbol)] = rawSymbol;
          }
        }

        print(
          "📊 ACTIVE SYMBOLS: ${_marketPairs.length}"
        );

      }


    }




    // ================= CANDLES =================


    final candles =
        data["candles"];



    if(candles is List){


      final echo =
          data["echo_req"] ?? {};



      final rawSymbol =
          echo["ticks_history"] ?? "";



      final symbol =
          normalizeSymbol(
            rawSymbol.toString()
          );



      if(symbol.isEmpty) return;



      final gran =
          echo["granularity"] ?? 60;



      final tf =
          _mapTF(gran);



      final parsed =
          <model.Candle>[];



      for(final c in candles){


        if(c is Map){


          parsed.add(
            model.Candle(

              epoch:
                  c["epoch"] ?? 0,


              open:
                  double.tryParse(
                    c["open"].toString()
                  ) ?? 0,


              high:
                  double.tryParse(
                    c["high"].toString()
                  ) ?? 0,


              low:
                  double.tryParse(
                    c["low"].toString()
                  ) ?? 0,


              close:
                  double.tryParse(
                    c["close"].toString()
                  ) ?? 0,


              volume:
                  double.tryParse(
                    c["volume"].toString()
                  ) ?? 0,

            ),
          );


        }

      }



      _set(
        symbol,
        tf,
        parsed,
      );



      print(
        "📥 CACHED $symbol ${tf.name}: ${parsed.length} candles"
      );



      _stream.add({

        "type":
            "candles_update",


        "symbol":
            symbol,


        "tf":
            tf.name,


        "length":
            parsed.length,

      });


    }


  }



// =====================================================
// PLACE TRADE
// COMPATIBILITY FOR trades.dart
// =====================================================

// 🚨 FIX MKUBWA (uwiano wa kimkakati kati ya uchambuzi na
// utekelezaji): awali kazi hii ilikuwa ikitumia CALL/PUT (binary
// options - "Rise/Fall") ambazo zina matatizo matatu makubwa:
//   1) HAZINA dhana ya Stop Loss/Take Profit kwa BEI HALISI kabisa -
//      zinafunga tu baada ya muda maalum ("duration"), bila kujali
//      bei imefika wapi. Injini ya uchambuzi (_analyze()) inahesabu
//      risk.stopLoss/risk.takeProfit kwa uangalifu (kutoka ATR) -
//      lakini hizo HAZIKUWAHI kutumika popote kwenye placeTrade() ya
//      awali - kazi mbili muhimu za mfumo (uchambuzi na utekelezaji)
//      hazikuwa zikiongea kabisa.
//   2) Ilikuwa HAINA "duration"/"duration_unit" kabisa - fields za
//      LAZIMA kwa CALL/PUT. Kila ombi la "proposal" lilikuwa
//      likikataliwa na Deriv, hivyo placeTrade() ILIKUWA IKISHINDWA
//      100% ya nyakati (hata kama masharti mengine yote yalikuwa sahihi).
//   3) 'symbol' iliyotumwa kwa Deriv ilikuwa UPPERCASE (bug ile ile ya
//      casing tuliyoirekebisha kwenye subscribeCandles/
//      fetchHistoricalRange - FRX/CRY/STPRNG zisingefanya kazi hata
//      baada ya (1) na (2) kurekebishwa).
//
// SASA: MULTUP/MULTDOWN (Multiplier contracts) zinatumika badala yake
// - hizi ZINAUNGA MKONO 'limit_order: {stop_loss, take_profit}' HALISI,
// zikitumia risk.stopLoss/risk.takeProfit zilizohesabiwa na injini -
// hakuna "duration" ya lazima (position inabaki wazi hadi SL/TP
// ifikiwe, au ufunge mwenyewe kwa mkono).
//
// ⚠️ MUHIMU #1: Deriv 'limit_order.stop_loss'/'take_profit' kwenye
// Multipliers ni KWA FEDHA (kiasi cha hasara/faida katika currency ya
// akaunti - USD), SI bei ghafi ya soko. Kwa hiyo tunahesabu kiasi cha
// fedha kinacholingana na asilimia ya mabadiliko ya bei (kutoka
// entryPrice/stopLossPrice/takeProfitPrice) ukizidisha na 'multiplier'
// na 'stake'.
//
// ⚠️ MUHIMU #2: thamani halali za 'multiplier' HUTOFAUTIANA kwa kila
// alama na account (mf. synthetics zinaweza kuruhusu hadi 100x-1000x,
// forex huenda ikawa chache zaidi) - default ya 100 hapa ni ya kawaida
// TU. Kabla ya kutumia kwenye akaunti ya pesa halisi, THIBITISHA
// multiplier halali kwa kila alama kwa kutumia ombi la 'contracts_for'
// (halijatengenezwa humu - nikuongezee ukihitaji).
Future<String?> placeTrade(
  String pair,
  bool isBuy, {
  double stake = 10,
  double? entryPrice,
  double? stopLossPrice,
  double? takeProfitPrice,
  int multiplier = 100,
}) async {

  final symbol = normalizeSymbol(pair);

  try {

    // Tengeneza 'limit_order' (SL/TP kwa fedha) TU kama tuna bei za
    // kutosha za kuhesabia - vinginevyo trade inafunguliwa bila
    // ulinzi wa SL/TP (hatari - epuka hili kwenye pesa halisi).
    final Map<String, dynamic> limitOrder = {};

    if (entryPrice != null && entryPrice > 0) {

      if (stopLossPrice != null) {
        final slPercent = (entryPrice - stopLossPrice).abs() / entryPrice;
        final slAmount = stake * multiplier * slPercent;
        limitOrder["stop_loss"] = double.parse(slAmount.toStringAsFixed(2));
      }

      if (takeProfitPrice != null) {
        final tpPercent = (takeProfitPrice - entryPrice).abs() / entryPrice;
        final tpAmount = stake * multiplier * tpPercent;
        limitOrder["take_profit"] = double.parse(tpAmount.toStringAsFixed(2));
      }
    }

    if (limitOrder.isEmpty) {
      print(
        "⚠️ placeTrade($symbol): hakuna entryPrice/SL/TP zilizotolewa - "
        "trade itafunguliwa BILA ulinzi wa Stop Loss/Take Profit.",
      );
    }

    // 1. GET PROPOSAL
    final proposalCompleter = Completer<Map<String, dynamic>>();
    late StreamSubscription proposalSub;

    proposalSub = stream.listen((event) {
      if (event["msg_type"] == "proposal") {
        if (!proposalCompleter.isCompleted) {
          proposalCompleter.complete(event);
        }
        proposalSub.cancel();
      } else if (event["msg_type"] == "error") {
        // FIX: awali "error" haikuwahi kumaliza (complete) hii
        // completer - ombi lililoshindwa lingesubiri MUDA WOTE hadi
        // timeout ya sekunde 10 badala ya kushindwa mara moja kwa
        // ujumbe wazi wa sababu.
        if (!proposalCompleter.isCompleted) {
          proposalCompleter.complete(event);
        }
        proposalSub.cancel();
      }
    });

    _send({
      "proposal": 1,
      "amount": stake,
      "basis": "stake",
      "contract_type": isBuy ? "MULTUP" : "MULTDOWN",
      "currency": "USD",
      // FIX (casing): 'pair' (jina halisi), si 'symbol' (UPPERCASE) -
      // bug ile ile iliyofanywa mahali pengine kwenye faili hii.
      "symbol": pair,
      "multiplier": multiplier,
      if (limitOrder.isNotEmpty) "limit_order": limitOrder,
    });

    final proposal = await proposalCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => <String, dynamic>{},
    );

    if (proposal["msg_type"] == "error") {
      print(
        "❌ Proposal error ($symbol): "
        "${proposal["error"]?["message"] ?? proposal["error"]}",
      );
      return null;
    }

    final p = proposal["proposal"];

    if (p == null) {
      print("❌ Proposal failed ($symbol) - hakuna jibu kutoka Deriv.");
      return null;
    }

    // 2. BUY CONTRACT
    final buyCompleter = Completer<Map<String, dynamic>>();
    late StreamSubscription buySub;

    buySub = stream.listen((event) {
      if (event["msg_type"] == "buy") {
        if (!buyCompleter.isCompleted) {
          buyCompleter.complete(event);
        }
        buySub.cancel();
      } else if (event["msg_type"] == "error") {
        if (!buyCompleter.isCompleted) {
          buyCompleter.complete(event);
        }
        buySub.cancel();
      }
    });

    _send({
      "buy": p["id"],
      "price": p["ask_price"] ?? stake,
    });

    final buy = await buyCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => <String, dynamic>{},
    );

    if (buy["msg_type"] == "error") {
      print(
        "❌ Buy error ($symbol): "
        "${buy["error"]?["message"] ?? buy["error"]}",
      );
      return null;
    }

    final contractId = buy["buy"]?["contract_id"]?.toString();

    if (contractId != null) {
      print(
        "✅ TRADE OPENED $symbol ID:$contractId "
        "(${isBuy ? "MULTUP" : "MULTDOWN"} ${multiplier}x "
        "SL:${limitOrder["stop_loss"] ?? "N/A"} "
        "TP:${limitOrder["take_profit"] ?? "N/A"})",
      );
    }

    return contractId;

  } catch (e) {

    print(
      "❌ placeTrade error ($symbol): $e"
    );

    return null;

  }

}


  // =====================================================
  // UPDATE CONTRACT SL/TP (ONGEZO JIPYA)
  // =====================================================
  //
  // MADHUMUNI: kubadilisha SL/TP HALISI za contract iliyo wazi tayari
  // kwenye Deriv - kupitia ombi la 'contract_update' (limethibitishwa
  // kutoka developers.deriv.com/comparison/contract-update/). Hii
  // ndiyo njia PEKEE ya kufanya "breakeven"/"TP extension" kuwa
  // HALISI upande wa Deriv - bila hii, mabadiliko ya SL/TP ni ya
  // NDANI TU (kwenye kumbukumbu ya server), Deriv haijui kabisa kuhusu
  // mabadiliko hayo, na 'limit_order' ya AWALI (wakati wa
  // kufungua trade) ndiyo pekee inayotekelezwa kama muunganisho
  // ukikatika.
  //
  // ⚠️ MUHIMU: Deriv 'limit_order.stop_loss'/'take_profit' kwenye
  // 'contract_update' ni KWA FEDHA (kiasi cha hasara/faida - USD), SI
  // bei ghafi ya soko - SAWA KABISA na 'placeTrade()'. Kwa hiyo
  // tunahitaji 'entryPrice'/'stake'/'multiplier' za AWALI (kutoka
  // wakati trade ilipofunguliwa) kuhesabu kiasi sahihi cha fedha kwa
  // bei mpya ya SL/TP.
  Future<bool> updateContractSLTP(
    String contractId, {
    double? newStopLossPrice,
    double? newTakeProfitPrice,
    required double entryPrice,
    required double stake,
    required int multiplier,
  }) async {
    if (entryPrice <= 0) {
      print("⚠️ updateContractSLTP: entryPrice batili ($entryPrice).");
      return false;
    }

    final Map<String, dynamic> limitOrder = {};

    if (newStopLossPrice != null) {
      final slPercent = (entryPrice - newStopLossPrice).abs() / entryPrice;
      final slAmount = stake * multiplier * slPercent;
      limitOrder["stop_loss"] = double.parse(slAmount.toStringAsFixed(2));
    }

    if (newTakeProfitPrice != null) {
      final tpPercent = (newTakeProfitPrice - entryPrice).abs() / entryPrice;
      final tpAmount = stake * multiplier * tpPercent;
      limitOrder["take_profit"] = double.parse(tpAmount.toStringAsFixed(2));
    }

    if (limitOrder.isEmpty) {
      print("⚠️ updateContractSLTP: hakuna SL/TP mpya iliyotolewa.");
      return false;
    }

    final contractIdInt = int.tryParse(contractId);

    if (contractIdInt == null) {
      print("⚠️ updateContractSLTP: contractId si namba halali ($contractId).");
      return false;
    }

    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription sub;

    sub = stream.listen((event) {
      if (event["msg_type"] == "contract_update") {
        if (!completer.isCompleted) completer.complete(event);
        sub.cancel();
      } else if (event["msg_type"] == "error") {
        if (!completer.isCompleted) completer.complete(event);
        sub.cancel();
      }
    });

    _send({
      "contract_update": 1,
      "contract_id": contractIdInt,
      "limit_order": limitOrder,
    });

    final result = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => <String, dynamic>{},
    );

    if (result["msg_type"] == "error") {
      print(
        "❌ contract_update error ($contractId): "
        "${result["error"]?["message"] ?? result["error"]}",
      );
      return false;
    }

    final ok = result["contract_update"] != null;

    if (ok) {
      print(
        "✅ CONTRACT UPDATED $contractId: "
        "SL/TP mpya (fedha) => $limitOrder",
      );
    }

    return ok;
  }




  void _init(String symbol){
    _data.putIfAbsent(
      symbol,
      ()=>{
        TF.m1:[],
        TF.m15:[],
        TF.m30:[],
        TF.h1:[],
        TF.h4:[],
        TF.d1:[],
        TF.w1:[],
        TF.mn:[],
        TF.y1:[],
      },
    );
  }






  // =====================================================
  // SAVE CANDLES
  // =====================================================


  void _set(

    String symbol,

    TF tf,

    List<model.Candle> candles,

  ){


    _init(symbol);



    _data[symbol]![tf] =
        List.from(candles);



    // build missing TF

    _buildAll(symbol);


  }






  // =====================================================
// BUILD TIMEFRAMES
// =====================================================

void _buildAll(String symbol) {

  _init(symbol);

  // FIX / MABORESHO KUBWA (kwa ombi la mtumiaji): AWALI hapa M15, M30,
  // H1, H4, na D1 zilikuwa zikijengwa kwa "kukadiria" (aggregate) kutoka
  // candles za M1. Hilo ni tatizo halisi: M1 ina ukomo wa candles 5000
  // TU kwa ombi moja (~siku 3.5), hivyo H1/H4/D1 zilizojengwa kutokana
  // na hiyo zingekuwa FUPI SANA na zisizo sahihi ikilinganishwa na
  // kuomba H1/H4/D1 MOJA KWA MOJA kutoka Deriv (ambako kila moja ina
  // dirisha lake la candles 5000 - mf. H1 peke yake inafikia ~siku 208,
  // D1 peke yake inafikia ~miaka 13.6).
  //
  // SASA: HAKUNA "conversion"/kukadiria ya bei kati ya M1 na M15/M30/H1/
  // H4/D1 tena. Kila timeframe (M1, M15, M30, H1, H4, D1) LAZIMA
  // iombwe MOJA KWA MOJA kwa Deriv kwa granularity yake halisi (angalia
  // subscribeCandles() / subscribeStrategySet() / fetchHistoricalRange()) -
  // data ya kila TF inatoka moja kwa moja kwenye _handle() -> _set()
  // pale Deriv inaporudisha jibu la ombi hilo mahususi, si kwa
  // kuhesabiwa humu ndani.
  //
  // Kinachobaki kujengwa humu ndani ni W1 (wiki), MN (mwezi), na Y1
  // (mwaka) TU - hii haiepukiki kwa sababu Deriv HAINA granularity
  // halali ya wiki/mwezi/mwaka (granularity zinazokubalika ni hadi
  // 86400 = siku moja tu). Hii SI kukadiria bei: ni kupanga candles
  // HALISI za D1 zilizotoka Deriv moja kwa moja katika makundi ya
  // kalenda (wiki/mwezi/mwaka), zikitumia open/high/low/close/volume
  // halisi bila kubadilisha thamani yoyote - njia hii hii hii ndiyo
  // MT4/MT5/TradingView zinatumia pia kwa sababu soko halina "wiki
  // candle" ya asili popote.
  final d1 = _data[symbol]?[TF.d1] ?? [];

  if (d1.length >= 5) {
    _data[symbol]![TF.w1] = buildWeekly(d1);
  }

  if (d1.length >= 20) {
    _data[symbol]![TF.mn] = buildMonthly(d1);
  }

  if (d1.length >= 200) {
    _data[symbol]![TF.y1] = buildYearly(d1);
  }
}

// FIX (msaidizi mpya): epuka kuandika upya (overwrite) TF fulani kwa
// data FUPI zaidi kuliko iliyopo tayari - inatumika na _buildAll
// kulinda data ndefu iliyopatikana moja kwa moja kutoka Deriv.
void _maybeReplaceIfLonger(
  String symbol,
  TF tf,
  List<model.Candle> candidate,
) {
  final current = _data[symbol]?[tf] ?? [];
  if (candidate.length > current.length) {
    _data[symbol]![tf] = candidate;
  }
}



List<model.Candle> buildWeekly(
    List<model.Candle> daily
){
  return _aggregateCalendar(daily, _CalendarUnit.week);
}

List<model.Candle> buildMonthly(
    List<model.Candle> daily
){
  return _aggregateCalendar(daily, _CalendarUnit.month);
}

List<model.Candle> buildYearly(
    List<model.Candle> daily
){
  return _aggregateCalendar(daily, _CalendarUnit.year);
}

// FIX / MABORESHO (multi-timeframe sahihi kwa kalenda halisi):
// Awali 'buildWeekly' pekee ndiyo ilikuwepo, na ilikuwa na mchanganyiko
// wa UTC/local usiolingana (bug). Kwa MAOMBI YA MTUMIAJI: hesabu hii
// SASA inatumia SAA ZA ENEO (local timezone) ya kifaa/server
// kinachoendesha injini kwa MAKUSUDI - si UTC. Hii ina maana:
//   - Mipaka ya wiki (Jumatatu 00:00 saa za eneo lako), mwezi (tarehe
//     1 saa za eneo lako), na mwaka (Januari 1 saa za eneo lako)
//     hutumika kujenga W1/MN1/Y1 kutoka D1.
//   - Backtest na uchambuzi wa moja kwa moja (live) ni SAHIHI KWA
//     KULINGANA ILA MRADI ikimbizwe daima kwenye kifaa/server chenye
//     saa za eneo LILE LILE (mf. daima Afrika Mashariki, EAT/UTC+3).
//     Ukibadilisha eneo la seva (mf. kuhamia server ya UTC au ya nchi
//     nyingine), matokeo ya W1/MN1/Y1 - na hivyo BIAS ya W1/D1
//     kwenye top-down analysis - yanaweza kubadilika kidogo kwa
//     candles zilizo mpakani mwa siku/wiki. Kama backtest itafanyika
//     kwenye seva tofauti na uchambuzi wa moja kwa moja, hakikisha
//     zote mbili zimewekwa TZ moja (mf. TZ=Africa/Nairobi) ili
//     matokeo yaendane.
List<model.Candle> _aggregateCalendar(
  List<model.Candle> daily,
  _CalendarUnit unit,
) {
  final result = <model.Candle>[];

  DateTime bucketStart(DateTime d) {
    switch (unit) {
      case _CalendarUnit.week:
        return DateTime(d.year, d.month, d.day - (d.weekday - 1));
      case _CalendarUnit.month:
        return DateTime(d.year, d.month, 1);
      case _CalendarUnit.year:
        return DateTime(d.year, 1, 1);
    }
  }

  for (final c in daily) {
    // Local timezone kwa MAKUSUDI (angalia maelezo hapo juu).
    final date = DateTime.fromMillisecondsSinceEpoch(c.epoch * 1000);
    final bucket = bucketStart(date);
    final bucketEpoch = bucket.millisecondsSinceEpoch ~/ 1000;

    if (result.isEmpty || result.last.epoch != bucketEpoch) {
      result.add(
        model.Candle(
          epoch: bucketEpoch,
          open: c.open,
          high: c.high,
          low: c.low,
          close: c.close,
          volume: c.volume,
        ),
      );
    } else {
      final last = result.last;
      result[result.length - 1] = model.Candle(
        epoch: last.epoch,
        open: last.open,
        high: max(last.high, c.high),
        low: min(last.low, c.low),
        close: c.close,
        volume: last.volume + c.volume,
      );
    }
  }

  return result;
}



  // =====================================================
  // SUBSCRIBE CANDLES
  // =====================================================
  //
  // FIX / MABORESHO (kadhaa muhimu hapa):
  //  1) 'count: 1000000' halikuwa na maana - Deriv ina ukomo halisi
  //     wa candles 5000 kwa ombi moja (ndiyo maana log zako zote
  //     zilionyesha "5000 candles"). Sasa 'count' inazuiwa (clamped)
  //     kwenye 5000.
  //  2) Haikuwa ikituma "subscribe": 1 - Deriv ilikuwa ikirudisha
  //     HISTORIA MOJA TU kisha kunyamaza; hakuna candle mpya
  //     iliyowahi "kusukumwa" (push) kwa injini - data ilikuwa
  //     "imeganda" tangu mzunguko wa kwanza. Sasa parameter 'live'
  //     (default true) inaongeza subscribe:1 kwa biashara ya kweli.
  //     Kwa BACKTEST tumia 'live:false' kuepuka WS subscriptions
  //     nyingi zisizohitajika.
  //  3) Hapakuwa na njia ya kulazimisha ombi jipya baada ya kushaomba
  //     mara moja. Sasa 'force:true' inaruhusu re-fetch (muhimu kwa
  //     periodic refresh na backtest ya vipindi tofauti).
  //  4) HAKUNA "conversion"/kukadiria kati ya timeframes: M15, M30, H1,
  //     H4, D1 - kila moja inaomba Deriv MOJA KWA MOJA kwa granularity
  //     yake halisi (mstari wa `granularity: ` hapa chini), kila moja
  //     ikiwa na dirisha lake LA PEKEE la candles 5000 (si kujengwa
  //     kutoka M1 au timeframe nyingine yoyote). Isipokuwa TU: TF.w1/
  //     TF.mn/TF.y1 (wiki/mwezi/mwaka) SI granularity halali za Deriv
  //     (haziko kwenye orodha ya granularity zinazokubaliwa - kubwa
  //     zaidi ni 86400 = siku moja), hivyo hazina namna ya kuombwa moja
  //     kwa moja. Kwa hizo TU: tunaomba D1 (candles halisi kutoka
  //     Deriv, uwezo wa ~miaka 13.6 kwa ombi moja), kisha kuzipanga
  //     (si kukadiria bei) katika makundi ya kalenda (wiki/mwezi/mwaka)
  //     kwa saa za ENEO/local - angalia buildWeekly/buildMonthly/
  //     buildYearly.
  Future<void> subscribeCandles(
    String symbolRaw, {
    TF tf = TF.m1,
    int count = 5000,
    bool live = true,
    bool force = false,
  }) async {

    if (!_connected) {
      await connect();
    }

    // 🚨 FIX (BUG KUBWA SANA - sababu kuu FRX/CRY/STPRNG hazikuwahi
    // kupata data): 'symbol' (toleo la UPPERCASE kutoka
    // normalizeSymbol) awali lilikuwa likitumika MOJA KWA MOJA kama
    // thamani ya "ticks_history" iliyotumwa kwa Deriv halisi. Deriv
    // inahitaji jina LA HALISI la alama (mf. "frxEURUSD", "cryBTCUSD",
    // "stpRNG3" - herufi mchanganyiko kimakusudi), SI toleo la
    // UPPERCASE. Alama zenye herufi UPPERCASE kiasili (R_50, 1HZ100V,
    // BOOM500, JD50) hazikuathirika kwa sababu normalizeSymbol()
    // haikubadilisha chochote kwao - lakini FRX/CRY/STPRNG (herufi
    // mchanganyiko kiasili) zilitumwa kwa jina LISILO SAHIHI
    // (FRXEURUSD badala ya frxEURUSD), Deriv ikarudisha data TUPU
    // kimya kimya (si error wazi - Deriv ilikuwa ikiona jina hilo
    // kama "halijulikani", si "batili").
    //
    // Sasa: 'symbol' (UPPERCASE) inatumika TU kwa internal bookkeeping
    // (map key ya _data, _subscribed, na maandishi ya print) - wakati
    // 'symbolRaw' (jina HALISI, bila kubadilishwa) ndiyo inayotumwa
    // kwa Deriv kwenye "ticks_history".
    final symbol = normalizeSymbol(symbolRaw);

    // ONGEZO JIPYA: jaza ramani ya casing hapa pia (si tu
    // active_symbols/getMarketPairs) - uimara wa ziada endapo
    // subscribeCandles() inatumika kabla ya getMarketPairs() kuwahi
    // kuitwa.
    _originalCasing[symbol] = symbolRaw;

    _init(symbol);

    // FIX #4: wiki/mwezi/mwaka hazina granularity halali Deriv -
    // zinajengwa kutoka D1.
    if (tf == TF.w1 || tf == TF.mn || tf == TF.y1) {
      await subscribeCandles(
        symbolRaw, // FIX: symbolRaw (jina halisi), si symbol (UPPERCASE)
        tf: TF.d1,
        count: count,
        live: live,
        force: force,
      );
      return;
    }

    final key = "${symbol}_${tf.name}";

    if (_subscribed.contains(key) && !force) {
      return;
    }

    _subscribed.add(key);

    // 🚨 FIX (bug hatari - angalia maelezo marefu kwenye tamko la
    // '_liveSubs'): tunatunza rekodi ya subscription hii TU kama
    // 'live:true' (subscriptions za mara moja tu, mf. backtest
    // historical fetch, hazihitaji kurejeshwa baada ya reconnect -
    // hazikuwa "live" hata kabla). Tunazuia rekodi za marudio (kama
    // 'force:true' ikiitwa mara kadhaa kwa symbol/tf ile ile).
    if (live) {
      final alreadyTracked = _liveSubs.any(
        (s) => s.symbolRaw == symbolRaw && s.tf == tf,
      );

      if (!alreadyTracked) {
        _liveSubs.add(_LiveSub(symbolRaw, tf));
      }
    }

    final granularity = _tfToSec(tf);

    // FIX #1: ukomo halisi wa Deriv ni candles 5000 kwa ombi moja.
    final safeCount = count > 5000 ? 5000 : (count < 1 ? 1 : count);

    print(
      "📡 SUBSCRIBE $symbol ${tf.name} (count:$safeCount live:$live) "
      "[Deriv symbol halisi: $symbolRaw]",
    );

    _send({
      "ticks_history": symbolRaw, // FIX: jina HALISI, si UPPERCASE
      "style": "candles",
      "granularity": granularity,
      "count": safeCount,
      "end": "latest",
      "adjust_start_time": 1,
      // FIX #2: bila hii, Deriv haitumi candle mpya kamwe baada ya
      // jibu la kwanza (data "inaganda").
      if (live) "subscribe": 1,
    });
  }

  // =====================================================
  // MFUMO KAMILI WA MUDA (mwaka -> mwezi -> wiki -> siku -> H4 -> H1
  // -> M30 -> M15) - ONGEZO JIPYA kwa maombi ya mtumiaji.
  // =====================================================
  //
  // Mgawanyo wa matumizi:
  //   - Y1 / MN1 / W1 / D1  : muktadha wa TREND/BIAS ya muda mrefu
  //                           (top-down bias, W1/D1 kwenye
  //                           market_analysis_service) NA msingi wa
  //                           kihistoria wa BACKTEST ya muda mrefu.
  //   - H4 / H1             : muundo wa soko (structure, order block,
  //                           liquidity) - top-down + entry timing.
  //   - M30 / M15           : muda wa kuingia halisi (entry timing
  //                           sahihi zaidi) na backtest ya kina
  //                           (granular) ya utekelezaji wa maagizo.
  //
  // D1 ikiombwa (count 5000 ~ miaka 13.6) inatosha kujenga W1/MN1/Y1
  // ndani ya kumbukumbu bila maombi ya ziada kwa Deriv. H4/H1/M30/M15
  // zinaombwa kila moja moja kwa moja kwa sababu D1 haiwezi kujengea
  // muda mfupi (huwezi kujenga H1 kutoka D1).
  Future<void> subscribeStrategySet(
    String symbolRaw, {
    bool live = true,
  }) async {
    // FIX (bug ile ile ya casing): 'symbol' (UPPERCASE) ilikuwa
    // ikipitishwa kwenda subscribeCandles() - ambayo (kabla ya fix)
    // ilikuwa ikituma jina hilo LISILO SAHIHI moja kwa moja kwa Deriv.
    // Sasa tunapitisha 'symbolRaw' (jina halisi) - subscribeCandles()
    // yenyewe italisawazisha kwa internal bookkeeping inapohitajika.

    // 1) Muktadha wa muda mrefu: D1 inatosha kujenga Y1/MN1/W1/D1 zote.
    await subscribeCandles(symbolRaw, tf: TF.d1, count: 5000, live: live);

    // 2) Muundo wa soko wa kati: H4, H1.
    await subscribeCandles(symbolRaw, tf: TF.h4, count: 5000, live: live);
    await subscribeCandles(symbolRaw, tf: TF.h1, count: 5000, live: live);

    // 3) Muda wa kuingia: M30, M15.
    await subscribeCandles(symbolRaw, tf: TF.m30, count: 5000, live: live);
    await subscribeCandles(symbolRaw, tf: TF.m15, count: 5000, live: live);
  }

  // =====================================================
  // HISTORIA NDEFU KWA BACKTEST HALISI (PAGINATION)
  // =====================================================
  //
  // ONGEZO JIPYA - halikuwepo kabisa awali. Deriv inarudisha candles
  // 5000 TU kwa ombi moja - hiyo haitoshi kwa BACKTEST HALISI ya
  // miaka kadhaa kwenye M15/M30/H1 (mf. candles 5000 za M15 ni siku
  // ~52 tu). Kazi hii inaomba kurasa (pages) nyingi mfululizo,
  // ikisogeza "end" kuelekea nyuma kila mara, hadi kufikia 'start'
  // uliyoitaka au hadi data ikiishe, kisha inaunganisha (dedupe) kila
  // kitu kuwa orodha moja inayoendelea (continuous).
  //
  // MFANO WA MATUMIZI (backtest ya miaka 2 ya H1):
  //   final candles = await DerivService.instance.fetchHistoricalRange(
  //     "R_100", TF.h1,
  //     start: DateTime.now().subtract(const Duration(days: 730)),
  //   );
  Future<List<model.Candle>> fetchHistoricalRange(
    String symbolRaw,
    TF tf, {
    required DateTime start,
    DateTime? end,
    Duration pageDelay = const Duration(milliseconds: 300),
  }) async {
    // FIX (bug ile ile ya casing - angalia maelezo marefu kwenye
    // subscribeCandles): 'symbol' (UPPERCASE) ilikuwa ikitumwa moja
    // kwa moja kwa Deriv - sasa 'symbolRaw' (jina halisi) ndiyo
    // inayotumwa, 'symbol' inabaki kwa matumizi ya ndani tu (kama
    // ikihitajika baadaye).
    final symbol = normalizeSymbol(symbolRaw);

    // Wiki/Mwezi/Mwaka hazina granularity halali Deriv - zichukuliwe
    // kutoka D1 kisha zijengwe humu ndani kwa kalenda (local time).
    if (tf == TF.w1 || tf == TF.mn || tf == TF.y1) {
      final daily = await fetchHistoricalRange(
        symbolRaw, // FIX: symbolRaw (jina halisi), si symbol
        TF.d1,
        start: start,
        end: end,
        pageDelay: pageDelay,
      );

      switch (tf) {
        case TF.w1:
          return buildWeekly(daily);
        case TF.mn:
          return buildMonthly(daily);
        case TF.y1:
          return buildYearly(daily);
        default:
          return daily;
      }
    }

    if (!_connected) {
      await connect();
    }

    // 🚨 FIX (bug hatari - sababu ya "candles 0" kwenye backtest):
    // awali hapa hapakuwa na uhakika wa kusubiri 'authorize'
    // kuthibitika kabla ya kutuma ombi la 'ticks_history'. Tofauti na
    // 'subscribeCandles()' ya moja kwa moja (inayoitwa mara chache,
    // ikiwa na muda wa kutosha wa kusubiri kabla ya matumizi), backtest
    // (kupitia 'runBacktest()') inaita 'fetchHistoricalRange()' MARA
    // MOJA TU baada ya 'connect()' kuanzishwa - na kwa vile
    // 'connect()' inarudi (returns) MARA MOJA baada ya kuanzisha
    // muunganiko wa WebSocket (bila kusubiri jibu la 'authorize'),
    // ombi la KWANZA la historia lilikuwa likitumwa KABLA Deriv
    // haijathibitisha akaunti - Deriv ilikuwa ikirudisha ORODHA TUPU
    // (candles 0) kimya kimya, si error wazi. Hii ndiyo iliyosababisha
    // "❌ BACKTEST: data haitoshi" kwa ALAMA ZOTE kwenye jaribio hili.
    //
    // Sasa: tunasubiri (poll) hadi 'authorize' ithibitike (hadi
    // sekunde 15) kabla ya kuendelea na maombi ya historia.
    if (!_auth) {
      const maxWait = Duration(seconds: 15);
      const pollEvery = Duration(milliseconds: 200);
      final deadline = DateTime.now().add(maxWait);

      while (!_auth && DateTime.now().isBefore(deadline)) {
        await Future.delayed(pollEvery);
      }

      if (!_auth) {
        print(
          "⚠️ fetchHistoricalRange($symbolRaw): authorize haijathibitika "
          "baada ya ${maxWait.inSeconds}s - data inaweza kuwa tupu.",
        );
      }
    }

    final granularity = _tfToSec(tf);
    final startEpoch = start.toUtc().millisecondsSinceEpoch ~/ 1000;

    int cursorEnd =
        (end ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;

    final collected = <model.Candle>[];
    final seenEpochs = <int>{};

    // Kikomo cha usalama dhidi ya mzunguko usio na mwisho (mf. Deriv
    // ikirudisha 'end' isiyoendelea kupungua kwa sababu yoyote).
    const maxPages = 500;
    int pages = 0;

    while (pages < maxPages) {
      pages++;

      // FIX: symbolRaw (jina halisi), si symbol (UPPERCASE).
      final page = await _fetchCandlesPage(symbolRaw, granularity, cursorEnd);

      if (page.isEmpty) break;

      for (final c in page) {
        if (seenEpochs.add(c.epoch)) {
          collected.add(c);
        }
      }

      final earliest = page.first.epoch;

      if (earliest <= startEpoch) break;

      final newEnd = earliest - 1;

      if (newEnd >= cursorEnd) {
        // Deriv haikupunguza 'end' - simama ili kuepuka kuomba mzunguko
        // usio na mwisho.
        break;
      }

      cursorEnd = newEnd;

      await Future.delayed(pageDelay);
    }

    collected.sort((a, b) => a.epoch.compareTo(b.epoch));

    final filtered =
        collected.where((c) => c.epoch >= startEpoch).toList();

    print(
      "📚 HISTORICAL $symbol ${tf.name}: ${filtered.length} candles "
      "(kurasa $pages) kuanzia ${start.toIso8601String()}",
    );

    // Hifadhi kwenye cache ya ndani pia, ikilinda data ndefu iliyopo
    // dhidi ya kubadilishwa na kitu kifupi zaidi.
    _init(symbol);
    _maybeReplaceIfLonger(symbol, tf, filtered);
    _buildAll(symbol);

    return filtered;
  }

  // Msaidizi wa ndani: omba ukurasa MMOJA wa candles (hadi 5000) ukiisha
  // kwa 'endEpoch' fulani, bila kujisajili (subscribe) kwa mabadiliko
  // ya moja kwa moja. Inatumia req_id kuoanisha ombi na jibu lake hasa
  // (muhimu wakati subscriptions nyingine za moja kwa moja zinaendelea
  // kutuma matukio kwenye stream ile ile wakati huo huo).
  Future<List<model.Candle>> _fetchCandlesPage(
    String symbol,
    int granularity,
    int endEpoch,
  ) async {
    final reqId = ++_reqIdCounter;

    final completer = Completer<List<model.Candle>>();

    late StreamSubscription sub;

    sub = stream.listen((event) {
      if (event["req_id"] != reqId) return;

      if (event["msg_type"] == "candles") {
        final raw = event["candles"];
        final list = <model.Candle>[];

        if (raw is List) {
          for (final c in raw) {
            if (c is Map) {
              list.add(
                model.Candle(
                  epoch: c["epoch"] ?? 0,
                  open: double.tryParse(c["open"].toString()) ?? 0,
                  high: double.tryParse(c["high"].toString()) ?? 0,
                  low: double.tryParse(c["low"].toString()) ?? 0,
                  close: double.tryParse(c["close"].toString()) ?? 0,
                  volume: double.tryParse(c["volume"].toString()) ?? 0,
                ),
              );
            }
          }
        }

        if (!completer.isCompleted) completer.complete(list);
        sub.cancel();
      } else if (event["msg_type"] == "error") {
        if (!completer.isCompleted) completer.complete(<model.Candle>[]);
        sub.cancel();
      }
    });

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": granularity,
      "count": 5000,
      "end": endEpoch,
      "req_id": reqId,
    });

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        sub.cancel();
        return <model.Candle>[];
      },
    );
  }






  // compatibility with old code

  Future<void> subscribe(
    String symbolRaw, {
    TF tf = TF.m1,
  }) async {


    await subscribeCandles(
      symbolRaw,
      tf: tf,
    );


  }







  // =====================================================
  // GET CANDLES
  // =====================================================


  List<model.Candle> getCandles(

    String symbolRaw,

    TF tf,

  ){


    final symbol =
        normalizeSymbol(symbolRaw);



    return
        _data[symbol]?[tf]
        ??
        [];


  }

  // =====================================================
  // IS READY
  // =====================================================
  //
  // FIX (method iliyorudishwa kwa usalama wa API): faili ya awali
  // ilikuwa na 'isReady(symbol)' inayotumika na sehemu nyingine za app
  // yako (mf. servers/signals_server.dart) - ilipotea wakati wa
  // uandishi upya. Sasa imerudishwa, LAKINI kwa vigezo VILE VILE
  // HALISI vinavyotumika na injini ya uchambuzi ndani ya
  // market_analysis_service.dart (h1>=120, h4>=50, d1>=50, w1>=20) -
  // si vigezo vya kubuni visivyohusiana na uchambuzi halisi kama
  // ilivyokuwa awali (m1>=10||h4>=10)&&h1>=5). Ikirudisha 'true' sasa
  // inamaanisha KWELI alama hii iko tayari kuchambuliwa kikamilifu.
  bool isReady(String symbolRaw) {
    final symbol = normalizeSymbol(symbolRaw);

    final h1 = _data[symbol]?[TF.h1]?.length ?? 0;
    final h4 = _data[symbol]?[TF.h4]?.length ?? 0;
    final d1 = _data[symbol]?[TF.d1]?.length ?? 0;
    final w1 = _data[symbol]?[TF.w1]?.length ?? 0;

    return h1 >= 120 && h4 >= 50 && d1 >= 50 && w1 >= 20;
  }








  // =====================================================
  // GET CANDLES WITH TF
  // =====================================================


  Future<List<model.Candle>>
      getCandlesWithTF(

    String pair, {

    TF timeframe = TF.m1,

  }) async {



    await subscribeCandles(

      pair,

      tf: timeframe,

    );



    await Future.delayed(

      const Duration(seconds:2),

    );



    return getCandles(

      pair,

      timeframe,

    );


  }






  // =====================================================
  // LAST PRICE
  // =====================================================


  Future<double> getLastPrice(
      String pair,
  ) async {



    final candles =
        getCandles(

          pair,

          TF.m1,

        );



    if(candles.isNotEmpty){


      return candles.last.close;


    }



    await subscribeCandles(

      pair,

      tf:TF.m1,

    );



    await Future.delayed(

      const Duration(seconds:2),

    );



    final retry =
        getCandles(

          pair,

          TF.m1,

        );



    if(retry.isNotEmpty){

      return retry.last.close;

    }



    return 0;


  }








  // =====================================================
  // ENSURE READY
  // =====================================================


  bool _ready=false;



  Future<void> ensureReady() async {



    if(_ready) return;



    await connect();



    _ready=true;


  }







  // =====================================================
  // MARKET PAIRS
  // =====================================================


  Future<List<String>> getMarketPairs()
  async {

    // FIX (uhakika wa kusubiri): awali hapa kulikuwa na 'delay' ya
    // sekunde 2 KIPOFU (bila kujua kama jibu limeshafika kweli) - kama
    // muunganisho/authorize ulikuwa bado haujakamilika ndani ya hizo
    // sekunde 2 (jambo la kawaida kwenye ombi la kwanza kabisa baada
    // ya kuanzisha app), 'getMarketPairs()' ilikuwa ikirudisha orodha
    // TUPU AU FUPI bila onyo lolote. Sasa: tunasubiri (poll) hadi
    // 'authorize' ithibitike NA '_marketPairs' ijazwe, hadi ukomo wa
    // sekunde 10 - na tunatoa ujumbe wazi kama muda umeisha.

    if (!_connected) {
      await connect();
    }

    const maxWait = Duration(seconds: 10);
    const pollEvery = Duration(milliseconds: 200);
    final deadline = DateTime.now().add(maxWait);

    // Subiri authorize ithibitike kwanza - 'active_symbols' inatumwa
    // KIOTOMATIKI na _handle() mara authorize ikithibitika (angalia
    // maelezo kwenye connect()/_handle()), hivyo hatuhitaji kutuma
    // ombi jipya hapa kwa mzunguko wa kawaida.
    while (!_auth && DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollEvery);
    }

    if (!_auth) {
      print(
        "⚠️ getMarketPairs(): authorize haijathibitika baada ya "
        "${maxWait.inSeconds}s - orodha inaweza kuwa haijakamilika.",
      );
    }

    // Subiri '_marketPairs' ijazwe (jibu la active_symbols limefika).
    while (_marketPairs.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollEvery);
    }

    if (_marketPairs.isEmpty) {
      // Jaribio la mwisho la wazi - lazimisha ombi jipya na subiri
      // kidogo zaidi, badala ya kurudisha orodha tupu kimya kimya.
      print(
        "⚠️ getMarketPairs(): _marketPairs bado tupu baada ya "
        "${maxWait.inSeconds}s - kutuma ombi la ziada la active_symbols.",
      );
      _send({"active_symbols": "brief"});
      await Future.delayed(const Duration(seconds: 3));
    }

    print("📊 getMarketPairs(): alama ${_marketPairs.length} zimepatikana.");

    return _marketPairs;

  }







  // =====================================================
  // SYNTHETIC DETECTION
  // =====================================================


  bool isSynthetic(String symbol){


    final s =
        symbol.toUpperCase();



    return

      s.startsWith("R_") ||

      s.startsWith("1HZ") ||

      s.startsWith("BOOM") ||

      s.startsWith("CRASH") ||

      s.startsWith("JD") ||

      s.startsWith("STPRNG");



  }





  // =====================================================
  // NORMALIZER
  // =====================================================


  String normalizeSymbol(String raw){


    String s =
        raw.trim()
        .toUpperCase();



    s =
      s.replaceAll(
        RegExp(r'[^A-Z0-9_]'),
        '',
      );



    return s;


  }
  // =====================================================
  // SEND
  // =====================================================


  void _send(
    Map<String,dynamic> data,
  ){


    try{


      if(_channel != null){

        _channel!.sink.add(
          jsonEncode(data),
        );


      }


    }catch(e){


      print(
        "❌ SEND ERROR $e"
      );


    }


  }








  // =====================================================
  // RECONNECT
  // =====================================================


  Future<void> _reconnect() async {


    print(
      "🔁 DERIV RECONNECTING..."
    );



    _connected=false;

    _auth=false;

    // FIX (usafi wa hali - angalia maelezo marefu kwenye _handle()
    // sehemu ya "authorize"): funguo za '_subscribed' za session ya
    // ZAMANI hazina maana tena kwenye muunganiko MPYA - Deriv haina
    // kumbukumbu yoyote ya subscriptions za awali. Ombi jipya la
    // resubscribe (ndani ya _handle() baada ya authorize) linatumia
    // 'force:true' hivyo halihitaji hii ili kufanya kazi, lakini
    // kuzifuta hapa kunaondoa hali ya "kuchanganyikiwa" isiyo na maana.
    _subscribed.clear();



    await Future.delayed(

      const Duration(seconds:3),

    );



    await connect(_token);



  }








  // =====================================================
  // CONTRACT STREAM
  // (COMPATIBILITY FOR trades.dart)
  // =====================================================


  StreamSubscription subscribeContract(

    String id,

    Function(
      Map<String,dynamic>
    ) onUpdate,

  ){



    return stream.listen(

      (event){



        final cid =

            event["contract_id"]
            ?.toString();



        if(cid != null &&

            cid == id.toString()){


          onUpdate(event);


        }



      },

    );


  }








  // =====================================================
  // CLOSE TRADE
  // =====================================================


  Future<void> closeTradeById(
      String id,
  ) async {



    _send({

      "forget":
          id,

    });



  }








  // =====================================================
  // BALANCE COMPATIBILITY
  // =====================================================


  double _balance = 0;



  // 🚨 ONGEZO JIPYA (fix ya "AuthorizationRequired" isiyotarajiwa chini
  // ya mzigo mkubwa): tuligundua (kupitia uchunguzi wa kina) kwamba
  // wakati wa 'bootstrap' yenye mzigo mkubwa (alama 92 zikijisajili),
  // muunganiko unaweza kukatika/kuungana upya KIMYA KIMYA (reconnect),
  // na ombi la 'balance' lililotumwa KABLA ya hilo linabaki likisubiri
  // jibu ambalo Deriv inalichakata kwenye SESSION MPYA isiyo na
  // authorize bado - likitoa "AuthorizationRequired" HATA KAMA TOKEN
  // NI SAHIHI (ilithibitishwa kwenye Deriv Playground).
  //
  // Sasa 'getBalance()' (jina la umma) ni WRAPPER inayojaribu tena
  // MOJA KWA MOJA (hadi mara 3) endapo itagundua '_auth' ilikuwa
  // FALSE kabla au baada ya jaribio - ishara kwamba reconnect
  // ilitokea wakati wa ombi hilo.
  Future<double> getBalance() async {
    const maxAttempts = 3;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final authBefore = _auth;

      final result = await _getBalanceOnce();

      final authAfter = _auth;

      // Kama auth ilikuwa (na ikabaki) 'true' wakati WOTE wa jaribio
      // hili, hatuna ishara ya reconnect - kubali matokeo (hata kama
      // ni 0.0 - inaweza kuwa balance halisi ya akaunti tupu).
      if (authBefore && authAfter) {
        return result;
      }

      if (attempt < maxAttempts) {
        print(
          "🔁 getBalance(): jaribio $attempt/$maxAttempts - auth "
          "ilikuwa isiyo imara (authBefore=$authBefore, "
          "authAfter=$authAfter) - uwezekano wa reconnect wakati wa "
          "ombi. Kusubiri kidogo kisha kujaribu tena...",
        );

        await Future.delayed(const Duration(seconds: 3));
      }
    }

    print(
      "❌ getBalance(): majaribio yote $maxAttempts yameshindwa kupata "
      "session imara - kurudisha matokeo ya mwisho ($_balance).",
    );

    return _balance;
  }

  Future<double> _getBalanceOnce()
  async {

    // 🚨 FIX (bug ile ile ya "muda" - sababu ya "$0 bila error"):
    // awali hapa hapakuwa na uhakika wa kusubiri 'authorize'
    // kuthibitika kabla ya kutuma ombi la "balance". Kama ombi
    // linatumwa KABLA Deriv haijathibitisha akaunti (jambo
    // linalowezekana SANA kwenye ombi la KWANZA la '/balance' mara
    // baada ya server kuanza - sawa kabisa na bugs za
    // 'getMarketPairs()'/'fetchHistoricalRange()' tulizozipata na
    // kuzirekebisha awali), Deriv haijibu ipasavyo, 'completer'
    // haikamiliki ndani ya sekunde 5, na function inarudi kwa
    // '_balance' YA DEFAULT (0) KIMYA KIMYA - bila error yoyote
    // inayoonekana. UI ilikuwa ikionyesha "$0" kihalali (si tatizo la
    // UI) kwa sababu server YENYEWE ilikuwa ikirudisha 0 halisi.
    //
    // Sasa: tunasubiri (poll) hadi 'authorize' ithibitike (hadi
    // sekunde 15) kabla ya kutuma ombi.
    if (!_connected) {
      await connect();
    }

    if (!_auth) {
      const maxWait = Duration(seconds: 15);
      const pollEvery = Duration(milliseconds: 200);
      final deadline = DateTime.now().add(maxWait);

      while (!_auth && DateTime.now().isBefore(deadline)) {
        await Future.delayed(pollEvery);
      }

      if (!_auth) {
        print(
          "⚠️ getBalance(): authorize haijathibitika baada ya "
          "${maxWait.inSeconds}s - balance inaweza kuwa si sahihi (0).",
        );
      }
    }

    final completer =
        Completer<double>();



    late StreamSubscription sub;

    // 🔍 ONGEZO JIPYA (diagnostic ya kina zaidi - kwa vile diagnostic
    // ya awali haikuwahi kuonekana kabisa, ikimaanisha 'msg_type ==
    // "balance"' haikuwahi kutokea): tunachapisha SASA kila 'event'
    // KAMILI inayofika kwenye stream wakati wa kusubiri jibu la
    // balance - hii itatuonyesha WAZI kama Deriv inatuma KITU CHOCHOTE
    // (hata kama si 'balance' - labda 'error', au 'msg_type' nyingine
    // isiyotarajiwa), au kama HAKUNA event yoyote inayofika kabisa
    // (ukimya kamili - ishara ya tatizo la muunganiko/WebSocket, si
    // la Deriv API).
    int eventCount = 0;

    sub =
        stream.listen(
          (event){

            eventCount++;
            print(
              "🔍 getBalance() event #$eventCount: "
              "msg_type=${event["msg_type"]} "
              "${event["msg_type"] == "error" ? "| ERROR: ${event["error"]}" : ""}",
            );


            if(event["msg_type"]=="balance"){


              final b =
                  event["balance"];

              // 🔍 ONGEZO JIPYA (diagnostic ya mwisho - hii ndiyo
              // itatuonyesha HASA kilichoshindikana): tuligundua
              // kwamba 'msg_type=="balance"' INAFIKA (event #1
              // kwenye jaribio la mwisho), lakini print ya
              // "💰 BALANCE (akaunti ya SASA/default)" HAIKUWAHI
              // kuonekana - ikimaanisha 'b is Map' hapa chini ilikuwa
              // FALSE. Hii inachapisha AINA HALISI na THAMANI HALISI
              // ya 'event["balance"]' ili tuone HASA Deriv ilituma
              // nini badala ya Map inayotarajiwa.
              print(
                "🔬 RAW event['balance']: aina=${b.runtimeType} "
                "thamani=$b | RAW EVENT NZIMA: $event",
              );

              if(b is Map){


                _balance =

                  double.tryParse(

                    b["balance"]
                    .toString(),

                  ) ??

                  0;

                // 🚨 ONGEZO JIPYA (diagnostic - kwa ombi la
                // mtumiaji): Deriv HAIRUDISHI balance ya AKAUNTI ZOTE
                // ulizonazo kwa default - inarudisha TU balance ya
                // AKAUNTI MOJA iliyounganishwa na token hii mahususi
                // (angalia 'loginid' hapa chini). Kama una akaunti
                // NYINGI (Real, Demo, Wallets tofauti za "Options"
                // dhidi ya "Multipliers/CFDs"), pesa yako HALISI
                // inaweza kuwa kwenye akaunti TOFAUTI na hii - $0
                // ingekuwa SAHIHI kihalali kwa akaunti hii mahususi,
                // hata kama una pesa mahali pengine. Sasa tunachapisha
                // AKAUNTI ZOTE zilizounganishwa (kutokana na
                // "account":"all" hapa chini) ili tuone wazi kama
                // kuna tofauti.
                print(
                  "💰 BALANCE (akaunti ya SASA/default): "
                  "${b["balance"]} ${b["currency"]} "
                  "(loginid: ${b["loginid"]})",
                );

                final accounts = b["accounts"];
                if (accounts is Map) {
                  print("💰 AKAUNTI ZOTE ZILIZOUNGANISHWA:");
                  accounts.forEach((loginId, info) {
                    if (info is Map) {
                      print(
                        "   $loginId : ${info["balance"]} "
                        "${info["currency"]} "
                        "(demo: ${info["demo_account"]}, "
                        "type: ${info["type"]})",
                      );
                    }
                  });
                  print(
                    "⚠️ Kama unaona akaunti YENYE PESA hapo juu "
                    "isiyo sawa na loginid ya default (${b["loginid"]}) "
                    "- hiyo ndiyo inayoshikilia fedha zako, si ile "
                    "inayotumika sasa na token hii.",
                  );
                }



                if(!completer.isCompleted){

                  completer.complete(
                    _balance,
                  );

                }


                sub.cancel();


              } else {

                // FIX: 'b' si Map - jaribu kuisoma moja kwa moja kama
                // namba (endapo Deriv ilituma thamani ghafi badala ya
                // Map iliyotarajiwa), na kamilisha 'completer' HATA
                // HIVYO badala ya kuiacha ikaishe muda bila sababu.
                final directValue = double.tryParse(b.toString());

                _balance = directValue ?? 0;

                print(
                  "⚠️ event['balance'] SI Map - jaribio la kuisoma "
                  "moja kwa moja kama namba: $_balance",
                );

                if(!completer.isCompleted){
                  completer.complete(_balance);
                }

                sub.cancel();

              }


            }



          },

        );



    // FIX (jaribio la kuondoa 'account:all' kwa muda - diagnostic):
    // tunataka kuthibitisha kama 'account:all' yenyewe ndiyo
    // inayosababisha tatizo (baadhi ya token hazitumii vizuri na
    // 'account:all'), au kama tatizo ni MUUNGANIKO kuwa na shughuli
    // nyingi (subscriptions 92 x timeframes 4 zikiendelea kutuma
    // 'ohlc' bila kukoma). Ombi limerahisishwa kwa 'balance:1' TU kwa
    // sasa - tutaongeza 'account:all' tena baadaye ikiwa hii itafanya
    // kazi.
    print(
      "📤 getBalance(): kutuma ombi la 'balance' sasa "
      "(_connected=$_connected, _auth=$_auth)...",
    );

    _send({

      "balance":1,

    });




    return completer.future.timeout(

      // 🚨 FIX (chanzo halisi kimepatikana kwa uhakika kupitia
      // diagnostic - angalia maelezo marefu kwenye maoni ya
      // 'eventCount' hapo juu): SEKUNDE 5 hazikuwa za kutosha - sio
      // kwa sababu Deriv inakataa ombi (hakuna 'error' kabisa
      // ilizingatiwa kwenye majaribio - events zote zilizopokelewa
      // wakati wa kusubiri zilikuwa 'candles'/'null', si 'balance'
      // wala 'error'), bali kwa sababu wakati wa BOOTSTRAP (alama
      // nyingi - 92 - zikipakia historia ya D1/H4/H1/M15 KWA WAKATI
      // MMOJA), muunganiko mmoja wa WebSocket unashughulikia MAMIA ya
      // ujumbe kwa zamu - ombi la "balance" linasubiri kwenye foleni
      // hiyo hiyo, na majibu yake yanachukua ZAIDI ya sekunde 5
      // kufika wakati wa msongamano huo. Sasa: sekunde 25 - muda wa
      // kutosha hata wakati wa bootstrap yenye shughuli nyingi.
      const Duration(seconds:25),

      onTimeout:(){

        sub.cancel();

        final reason = eventCount == 0
            ? "HAKUNA EVENT YOYOTE ilipokelewa - tatizo la muunganiko/WebSocket, si la Deriv API."
            : "Kulikuwa na events $eventCount lakini hakuna iliyokuwa "
              "msg_type==balance - uwezekano mkubwa: muunganiko "
              "ulikuwa na shughuli nyingi (bootstrap/subscriptions "
              "nyingi) wakati huo.";

        print(
          "⏱️ getBalance(): IMEISHA MUDA baada ya sekunde 25 - "
          "events zilizopokelewa wakati huo: $eventCount. $reason",
        );

        return _balance;

      },

    );

  }








  // =====================================================
  // TIMEFRAME CONVERTER
  // =====================================================
  //
  // FIX / MABORESHO: iliongezwa m15 (900s) na m30 (1800s) - hizi ni
  // granularity HALISI zinazokubalika na Deriv API, hivyo zinaombwa
  // moja kwa moja. w1/mn(mwezi)/y1(mwaka) SI granularity halali za
  // Deriv - hazina thamani sahihi ya sekunde ya kudumu (wiki/mwezi/
  // mwaka hazina idadi sawa ya siku kila mara), hivyo HAZIOMBWI kwa
  // Deriv moja kwa moja - zinajengwa humu ndani kutoka D1 kwa kalenda
  // sahihi (angalia buildWeekly/buildMonthly/buildYearly). Thamani
  // zilizorudishwa hapa kwao ni kwa madhumuni ya UTILITY/estimate tu
  // (havitumiki kuomba Deriv).
  int _tfToSec(TF tf){
    switch(tf){
      case TF.m1:
        return 60;
      case TF.m15:
        return 900;
      case TF.m30:
        return 1800;
      case TF.h1:
        return 3600;
      case TF.h4:
        return 14400;
      case TF.d1:
        return 86400;
      case TF.w1:
        return 604800;
      case TF.mn:
        return 2592000; // estimate (siku 30) - haitumiki kuomba Deriv
      case TF.y1:
        return 31536000; // estimate (siku 365) - haitumiki kuomba Deriv
    }
  }

  TF _mapTF(int sec){
    switch(sec){
      case 60:
        return TF.m1;
      case 900:
        return TF.m15;
      case 1800:
        return TF.m30;
      case 3600:
        return TF.h1;
      case 14400:
        return TF.h4;
      case 86400:
        return TF.d1;
      case 604800:
        return TF.w1;
      case 2592000:
        return TF.mn;
      default:
        return TF.m1;
    }
  }






}
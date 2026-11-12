import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MiaparaApp());
}

class BHelper {
  static const bn = {'0':'০','1':'১','2':'২','3':'৩','4':'৪','5':'৫','6':'৬','7':'৭','8':'৮','9':'৯'};
  static const mNames = ['','জানুয়ারি','ফেব্রুয়ারি','মার্চ','এপ্রিল','মে','জুন','জুলাই','আগস্ট','সেপ্টেম্বর','অক্টোবর','নভেম্বর','ডিসেম্বর'];
  static String toBn(dynamic n) => n == null ? '০' : n.toString().split('').map((c) => bn[c] ?? c).join('');
  static String taka(int p) => '৳ ${toBn(p ~/ 100)}';
}

class MiaparaApp extends StatelessWidget {
  const MiaparaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(primarySwatch: Colors.teal, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F6)),
    home: const MainScreen(),
  );
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _tab = 0;
  Database? _db;
  bool _loading = true, _locked = false;
  bool _isSearchOpen = false;
  bool _isInitialized = false; // অটো ব্যাকআপ কন্ট্রোলার
  bool _backupInProgress = false;
  Timer? _autoBackupTimer;
  Timer? _periodicAutoBackupTimer;
  String _pin = '', _search = '', _mFilter = 'ALL', _cFilter = 'ALL';
  final _pinCtrl = TextEditingController(), _sCtrl = TextEditingController();
  int _cYear = DateTime.now().year, _cMonth = DateTime.now().month;
  int _opCash = 0, _opBank = 0, _cash = 0, _bank = 0, _mChanda = 0, _mInc = 0, _mExp = 0;
  
  List<Map<String, dynamic>> _members = [], _cashList = [];
  final GlobalKey _receiptKey = GlobalKey();
  final GlobalKey _auditKey = GlobalKey();

  final List<String> _defaultInCats = ['জুমার সাপ্তাহিক কালেকশন','মসজিদে মেস/ম্যাচ ভাড়া','মেসের বিদ্যুৎ বিল আদায়','এককালীন দান / অনুদান','মাদ্রাসায় দান','মাদ্রাসার ছাত্রদের বেতন আদায়','মাসিক চাঁদা','রমজান ইফতার ও তারাবিহ ফান্ড','কোরবানির চামড়া বিক্রির অর্থ','ফিতরা ও সদকা','মসজিদ উন্নয়ন বিশেষ অনুদান','অন্যান্য আয়'];
  final List<String> _defaultOutCats = ['ইমাম সাহেবের বেতন','মুয়াজ্জিন সাহেবের বেতন','খাদেমের বেতন','বিদ্যুৎ বিল','পানির বিল','মসজিদ সংস্কার ও মেরামত','রমজান ইফতার ও তারাবিহ খরচ','পরিচ্ছন্নতা সামগ্রী','অন্যান্য ব্যয়'];

  List<String> _inCats = [];
  List<String> _outCats = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inCats = List.from(_defaultInCats);
    _outCats = List.from(_defaultOutCats);
    _init();
  }

  Future<void> _init() async {
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'miapara_mosque_master_v8.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE members (id INTEGER PRIMARY KEY AUTOINCREMENT, book_sl INTEGER, name TEXT, phone TEXT, address TEXT DEFAULT "", monthly_rate INTEGER, member_type TEXT DEFAULT "MONTHLY", status TEXT DEFAULT "ACTIVE")');
        await db.execute('CREATE TABLE collections (id INTEGER PRIMARY KEY AUTOINCREMENT, member_id INTEGER, year INTEGER, month INTEGER, amount INTEGER, receipt_no TEXT, date TEXT, type TEXT, note TEXT)');
        await db.execute('CREATE TABLE cashbook (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, category TEXT, amount INTEGER, payment_method TEXT, voucher_no TEXT, date TEXT, note TEXT)');
        await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
        await db.insert('settings', {'key': 'opening_cash', 'value': '0'});
        await db.insert('settings', {'key': 'opening_bank', 'value': '0'});
        await db.insert('settings', {'key': 'app_pin', 'value': ''});
        await _seedMembers(db);
      },
      onOpen: (db) async {
        // পুরোনো ডাটাবেজে address কলাম না থাকলে নিরাপদে যোগ করা হবে।
        final memberColumns = await db.rawQuery('PRAGMA table_info(members)');
        if (!memberColumns.any((c) => c['name'] == 'address')) {
          await db.execute("ALTER TABLE members ADD COLUMN address TEXT DEFAULT ''");
        }
        await db.execute('CREATE TABLE IF NOT EXISTS custom_categories (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, name TEXT UNIQUE)');
        await db.execute('CREATE TABLE IF NOT EXISTS cashbook_items (id INTEGER PRIMARY KEY AUTOINCREMENT, cashbook_id INTEGER, title TEXT, amount INTEGER, date TEXT)');
      },
    );

    final pRes = await _db!.query('settings', where: 'key="app_pin"');
    if (pRes.isNotEmpty && pRes.first['value'].toString().trim().isNotEmpty) {
      _pin = pRes.first['value'].toString().trim();
      _locked = true;
    }
    _refresh();
  }

  Future<void> _seedMembers(Database db) async {
    const raw = 
      '2|নজরুল ইসলাম|300;3|গাজী হারুনুর রশীদ|200;4|মৃত আব্দুল মান্নান|220||D;6|মইনুদ্দিন তালুকদার|100;9|আরিফুল সজিব|500;10|শহিদুল ইসলাম|500;11|নজরুল ইসলাম (স্যার)|150;13|খানজাহান আলী|100;19|শাহেনা সুলতানা|200;20|মোসাদ্দেक সাহেব|200;21|ডাঃ বোরহান উদ্দিন|200;22|আব্দুজ জলিল সাহেব|100;24|হাজী ইসমাইল সাহেব|1000;25|হাজি তারিকুল ইসলাম|100;30|কামাল হওলাদার|50;31|জামিল হোসেন|100;32|মাহবুব আলম|200;33|বশির ভাই (গ্যারেজ)|100;34|জামাল হোসেন|100;36|মাসুদুর রহমান (ফার্নিচার)|50;39|মুজিবুর রহমান|50;42|সেলিম হওলাদার (মুদি)|100;43|ওসমান গানি সাহেব|1000;47|মৃত মনোয়ারুল ইসলাম|500||D;53|বাদশাহ মিয়া|200;54|হানিফ শেখ|100;56|সিরাজুল ইসলাম (সেক্রে:)|100;57|কামরুজ্জামান সাহেব|100;60|নিলুফা হক (দুর্বার মোড়)|100;62|আবুল কালাম (কার্পেন্ট)|100;64|আলি আহমেদ বাচ্চু|200;71|জাকির হোসেন সাহেব|100;72|মাহফুজ উল্লাহ সাহেব|200;79|হাঃ শামিম সাহেব|100;82|আব্দুর রহমান (দোকান)|50;83|জাফর হোসেন সাহেব|100;86|মৃত মকবুল মাষ্টার|50||D;87|মোস্তফা হাওলাদার|100;89|বেল্লাল শেখ|50;90|বেল্লাল সেলুন|50;91|ফিরোজা বেগম|100;92|মাহবুবুর রহমান|300;93|মিরাজুল ইসলাম|100;94|মৃত তিশা খাতুন|100||D;95|রবিউল ইসলাম|100;96|ফয়সাল আহমেদ (স্কুল)|100;98|তানভির আহমেদ|200;101|তরিকুল ইসলাম তরু|100;102|মাসুম বিল্লাহ সাহেব|200;103|হীরা সাহেব|100;104|মো: সাগর|200;105|জয়নাল হোটেল|50;106|ইদ্রিস আলি সাহেব|100;108|হাফিজুর রহমান (১)|100;109|তাহসিন সানি|100;110|মাসুক সাহেব|100;111|শাহিনুল ইসলাম|50;112|মোঃ মেহেদী|50;114|হাফিজুর রহ: (শিক্ষক)|50;116|রফিকুল ইসলাম|100;117|আকাশ শেখ|100;118|আনোয়ারুল হক|100;119|আল আমিন শেখ|100;120|আল আমিন এর আম্মা|100;122|জিয়া সাহেব|100;123|রিপন সাহেব|100;124|ইদ্রিস আলি (চা)|50;125|উজ্জ্বল (গ্যাস)|50;126|খলিল সাহেব (মুদি)|50;128|আবুল কালাম (মোহনা)|100;129|কাজল সাহেব (থাই)|100;130|নাহার পারভিন|100;131|নিগার সুলতানা|50;134|সফিকুল হক (ডা,সিরাজ)|200;135|ইব্রাহিম (রমিজ-টুকু)|100;140|ফারুক সিকদার (হোটেল)|50;143|শাহজাহান সাহেব|100;144|শহীদুল্লাহ সাহেব|100;145|মোত্তার হোসেন|100;146|মরহুম-আব্দুল্লাহ সাহেব|200||D;147|মিজানুর রহমান|200;149|সৌরভ (বাচ্চুর ছেলে)|100;150|ইয়াসিন ব্রাদার্স|50;151|পাপ্পু (মনির ভাই)|50;152|মো: রাজা (মাসুদ)|100;153|বাদল ভাই (বিসমিল্লাহ)|100;154|কবির খান (বিসমিল্লাহ)|100;155|সুমন শরীফ|200|M|A|01722252174;156|লাভু চৌধুরী|100;'
      '1|আবুল মুনসুর আল আজাদ|200|Y|A;5|তানভীরুল আজম সাহেব|200|Y|A;7|মৃত আহমাদ আলী|200|Y|D;8|মুসাহিদ উদ্দিন সাহেব (দিলন)|200|Y|A;12|সেলিম উল হক (লাভা)|200|Y|A;14|মৃত রফিকুল ইসলাম সাহেব|200|Y|D;15|আহসান হাবিব (হ্যাপি)|200|Y|A;16|মনিরুজ্জামান সাহেব|200|Y|A;17|আবু মুসা আজাদ (রেজাউল)|200|Y|A;18|আলতাফ হোসেন সাহেব|200|Y|A;23|কামরুল ফরাজি সাহেব|200|Y|A;27|মৃত আব্দুল হালিম সাহেব|200|Y|D;28|মাহফুজুর রহমান টুটুল|200|Y|A;29|নওশাদ হোসেন মোল্লা|200|Y|A;38|শফিউদ্দিন সফি|200|Y|A;41|শিরিন আহমেদ (বাঁটু)|200|Y|A;44|সাব্বির আহমেদ সাহেব|200|Y|A;50|মৃত আলতাফ হোসেন মোল্লা|200|Y|D;51|গোলাম ফেরদৌস সাহেব|200|Y|A;52|আব্দুর রশিদ সাহেব (পান্না)|200|Y|A;55|খুরশিদ আলম টিপু|200|Y|A;58|আব্দুজ জব্বার (বাপ্পি)|200|Y|A;59|মৃত শামসুদ্দিন সাহেব|200|Y|D;61|মৃত গোলাম মোহাম্মদ আলী|200|Y|D;63|লুৎফর রহমান সাহেব|200|Y|A;65|গোলাম মহিউদ্দিন সাহেব|200|Y|A;66|মৃত সোহরাব হোসেন|200|Y|D;67|আব্দুল লতিফ হাওলাদার|200|Y|A;68|রিয়াজুর রহমান সোহাগ|200|Y|A;69|মৃত মাহতাব উদ্দিন (বাবলু)|200|Y|D;70|আতাহারুল ইসলাম (বাবলু)|200|Y|A;74|মৃত আখতারুজ্জামান|200|Y|D;75|ফাহাদ আল মামুন (লালন)|200|Y|A;77|মনজুরুল ইসলাম (রাসেল)|200|Y|A;78|হাফেজ ইব্রাহিম কামাল|200|Y|A;81|মৃত আফতাব উদ্দিন (জাকির সা,)|200|Y|D;84|ইয়াসিন শেখ|200|Y|A;85|নজরুল ইসলাম মঞ্জু সাহেব|200|Y|A;88|শামসুদ্দিন সাহেব|200|Y|A;97|নূরনবী সাহেব (পুলিশ)|200|Y|A;99|আব্দুল হক সাহেব|200|Y|A;100|মরিয়ম আরা|200|Y|A;115|বোরহান উদ্দিন|200|Y|A;121|ইঞ্জি: নিজামুদ্দিন (সুমন)|200|Y|A;142|মিথিলা|200|Y|A';

    await db.transaction((txn) async {
      for (var it in raw.split(';')) {
        if (it.trim().isEmpty) continue;
        var pl = it.split('|');
        await txn.insert('members', {
          'book_sl': int.tryParse(pl[0]) ?? 0, 'name': pl[1],
          'monthly_rate': (int.tryParse(pl[2]) ?? 100) * 100,
          'member_type': pl.length > 3 && pl[3] == 'Y' ? 'YEARLY' : 'MONTHLY',
          'status': pl.length > 4 && pl[4] == 'D' ? 'DECEASED' : 'ACTIVE',
          'phone': pl.length > 5 ? pl[5] : '',
        });
      }
    });
  }

  Future<void> _refresh() async {
    if (_db == null) return;
    setState(() => _loading = true);

    final cIn = await _db!.query('custom_categories', where: 'type="INCOME"');
    final cOut = await _db!.query('custom_categories', where: 'type="EXPENSE"');
    _inCats = List.from(_defaultInCats)..addAll(cIn.map((e) => e['name'].toString()));
    _outCats = List.from(_defaultOutCats)..addAll(cOut.map((e) => e['name'].toString()));

    final oc = await _db!.query('settings', where: 'key="opening_cash"');
    _opCash = oc.isNotEmpty ? (int.tryParse(oc.first['value'].toString()) ?? 0) : 0;
    final ob = await _db!.query('settings', where: 'key="opening_bank"');
    _opBank = ob.isNotEmpty ? (int.tryParse(ob.first['value'].toString()) ?? 0) : 0;

    final cashIn = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='INCOME' AND payment_method='CASH'")).first['s'] as int;
    final cashOut = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='EXPENSE' AND payment_method='CASH'")).first['s'] as int;
    final tB = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='TRANSFER' AND payment_method='CASH_TO_BANK'")).first['s'] as int;
    final tC = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='TRANSFER' AND payment_method='BANK_TO_CASH'")).first['s'] as int;
    _cash = _opCash + cashIn - cashOut - tB + tC;

    final bIn = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='INCOME' AND payment_method='BANK'")).first['s'] as int;
    final bOut = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='EXPENSE' AND payment_method='BANK'")).first['s'] as int;
    _bank = _opBank + bIn - bOut + tB - tC;

    final mp = '$_cYear-${_cMonth.toString().padLeft(2, '0')}';
    _mChanda = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM collections WHERE substr(date,1,7)=?", [mp])).first['s'] as int;
    _mInc = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='INCOME' AND substr(date,1,7)=?", [mp])).first['s'] as int;
    _mExp = (await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook WHERE type='EXPENSE' AND substr(date,1,7)=?", [mp])).first['s'] as int;
    _cashList = await _db!.rawQuery("SELECT * FROM cashbook WHERE substr(date,1,7)=? ORDER BY date DESC, id DESC", [mp]);

    final rawM = await _db!.query('members', orderBy: 'book_sl ASC, id ASC');
    List<Map<String, dynamic>> res = [];
    for (var m in rawM) {
      final lp = await _db!.rawQuery("SELECT year, month FROM collections WHERE member_id=? ORDER BY year DESC, month DESC LIMIT 1", [m['id']]);
      String lpText = 'কোন জমা নেই';
      bool covered = false;
      if (lp.isNotEmpty) {
        final ly = lp.first['year'] as int, lm = lp.first['month'] as int;
        lpText = '${BHelper.mNames[lm]} ${BHelper.toBn(ly)} পর্যন্ত পরিশোধিত';
        covered = (ly * 12 + lm) >= (_cYear * 12 + _cMonth);
      }

      final thisMonthPaidCount = (await _db!.rawQuery(
        "SELECT COUNT(*) as c FROM collections WHERE member_id=? AND substr(date,1,7)=?",
        [m['id'], mp],
      )).first['c'] as int;

      res.add({
        ...m,
        'lp_text': lpText,
        'covered': covered,
        'paid_this_month': thisMonthPaidCount > 0,
      });
    }
    _members = res;
    setState(() => _loading = false);

    // প্রথম চালু হওয়ার পরও একবার অটো ব্যাকআপের চেষ্টা হবে।
    _isInitialized = true;
    _scheduleAutoBackup();

    // অ্যাপ খোলা থাকলে প্রতি ২৪ ঘণ্টায় অন্তত একবার ব্যাকআপের চেষ্টা।
    _periodicAutoBackupTimer ??= Timer.periodic(const Duration(hours: 24), (_) {
      if (mounted) _sendBackupToTelegram(showToast: false, isAuto: true);
    });
  }

  Future<String> _readSetting(String key, {String fallback = ''}) async {
    final rows = await _db!.query('settings', where: 'key=?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? fallback : (rows.first['value']?.toString() ?? fallback);
  }

  void _scheduleAutoBackup({Duration delay = const Duration(seconds: 8)}) {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer(delay, () {
      if (mounted) _sendBackupToTelegram(showToast: false, isAuto: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _checkAutoBackupOnResume();
    }
  }

  Future<void> _checkAutoBackupOnResume() async {
    if (_db == null) return;
    final last = await _readSetting('telegram_last_auto_backup');
    final lastTime = DateTime.tryParse(last);
    final due = lastTime == null ||
        DateTime.now().difference(lastTime) >= const Duration(hours: 24);
    if (due) {
      _scheduleAutoBackup(delay: const Duration(seconds: 3));
    }
  }

  Future<void> _configureTelegram() async {
    if (_db == null) return;
    final tokenC = TextEditingController(
      text: await _readSetting('telegram_bot_token'),
    );
    final chatC = TextEditingController(
      text: await _readSetting('telegram_chat_id', fallback: '845564540'),
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Telegram ব্যাকআপ সেটআপ'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'BotFather থেকে পাওয়া নতুন Bot Token এবং Telegram Chat ID দিন। Token গোপন রাখুন।',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenC,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Telegram Bot Token',
                  hintText: '123456:ABC-...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: chatC,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Telegram Chat ID',
                  hintText: 'যেমন: 845564540',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('বাতিল'),
          ),
          ElevatedButton(
            onPressed: () {
              if (tokenC.text.trim().isEmpty || chatC.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Bot Token এবং Chat ID দুটোই দিতে হবে।')),
                );
                return;
              }
              Navigator.pop(dialogContext, true);
            },
            child: const Text('সংরক্ষণ'),
          ),
        ],
      ),
    );

    if (saved == true) {
      await _db!.insert(
        'settings',
        {'key': 'telegram_bot_token', 'value': tokenC.text.trim()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _db!.insert(
        'settings',
        {'key': 'telegram_chat_id', 'value': chatC.text.trim()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Telegram সেটআপ সংরক্ষণ হয়েছে। এখন সংযোগ পরীক্ষা করে ব্যাকআপ পাঠাচ্ছি।')),
        );
      }
      await _sendBackupToTelegram(showToast: true);
    }
    tokenC.dispose();
    chatC.dispose();
  }

  // Telegram-এ সম্পূর্ণ SQLite ডেটার JSON ব্যাকআপ পাঠায়।
  Future<void> _sendBackupToTelegram({bool showToast = true, bool isAuto = false}) async {
    if (_db == null) return;
    if (_backupInProgress) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('একটি ব্যাকআপ ইতিমধ্যে পাঠানো হচ্ছে। একটু অপেক্ষা করুন।')),
        );
      } else if (isAuto) {
        // ম্যানুয়াল ব্যাকআপ চলার সময় অটো ব্যাকআপ বাদ না দিয়ে পরে আবার চেষ্টা করবে।
        _scheduleAutoBackup(delay: const Duration(seconds: 20));
      }
      return;
    }

    HttpClient? client;
    _backupInProgress = true;
    try {
      final token = await _readSetting('telegram_bot_token');
      final chatId = await _readSetting('telegram_chat_id', fallback: '845564540');

      if (token.trim().isEmpty || token.trim() == 'YOUR_NEW_TELEGRAM_BOT_TOKEN') {
        if (showToast && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('আগে “Telegram সেটআপ” থেকে Bot Token ও Chat ID সংরক্ষণ করুন।')),
          );
        }
        return;
      }

      final safeSettings = await _db!.query(
        'settings',
        where: 'key NOT IN (?, ?)',
        whereArgs: ['telegram_bot_token', 'telegram_chat_id'],
      );
      final bData = {
        'app': 'miapara_master_v8',
        'saved_at': DateTime.now().toIso8601String(),
        'members': await _db!.query('members'),
        'collections': await _db!.query('collections'),
        'cashbook': await _db!.query('cashbook'),
        'cashbook_items': await _db!.query('cashbook_items'),
        'custom_categories': await _db!.query('custom_categories'),
        'settings': safeSettings,
      };
      final jsonBytes = utf8.encode(jsonEncode(bData));
      final boundary = '----MiaparaTelegram${DateTime.now().microsecondsSinceEpoch}';
      final bytes = BytesBuilder();

      void addField(String name, String value) {
        bytes.add(utf8.encode('--$boundary\r\n'));
        bytes.add(utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'));
        bytes.add(utf8.encode('$value\r\n'));
      }

      void addFile(String name, String filename, List<int> fileBytes) {
        bytes.add(utf8.encode('--$boundary\r\n'));
        bytes.add(utf8.encode('Content-Disposition: form-data; name="$name"; filename="$filename"\r\n'));
        bytes.add(utf8.encode('Content-Type: application/json; charset=utf-8\r\n\r\n'));
        bytes.add(fileBytes);
        bytes.add(utf8.encode('\r\n'));
      }

      addField('chat_id', chatId.trim());
      addField(
        'caption',
        '🕌 মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ - ডেটাবেজ ব্যাকআপ\n'
        'তারিখ: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}',
      );
      addFile(
        'document',
        'miapara_backup_${DateTime.now().millisecondsSinceEpoch}.json',
        jsonBytes,
      );
      bytes.add(utf8.encode('--$boundary--\r\n'));

      client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
      final uri = Uri.parse('https://api.telegram.org/bot${token.trim()}/sendDocument');
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 30));
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      final payload = bytes.toBytes();
      request.contentLength = payload.length;
      request.add(payload);

      final response = await request.close().timeout(const Duration(seconds: 60));
      final responseText = await utf8.decoder.bind(response).join();
      Map<String, dynamic> result = {};
      try {
        result = Map<String, dynamic>.from(jsonDecode(responseText));
      } catch (_) {}

      if (response.statusCode != 200 || result['ok'] != true) {
        final description = result['description']?.toString() ?? 'HTTP ${response.statusCode}';
        throw Exception(description);
      }

      if (isAuto) {
        await _db!.insert(
          'settings',
          {'key': 'telegram_last_auto_backup', 'value': DateTime.now().toIso8601String()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('আলহামদুলিল্লাহ! Telegram-এ ব্যাকআপ সফলভাবে পাঠানো হয়েছে।')),
        );
      }
    } catch (e) {
      if (showToast && mounted) {
        final message = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Telegram ব্যাকআপ ব্যর্থ: $message')),
        );
      } else if (isAuto && mounted) {
        // নেটওয়ার্ক সাময়িকভাবে না থাকলে ৫ মিনিট পর আবার চেষ্টা।
        _scheduleAutoBackup(delay: const Duration(minutes: 5));
      }
    } finally {
      client?.close(force: true);
      _backupInProgress = false;
    }
  }

  Future<void> _restoreFromJsonString(String str) async {
    try {
      final m = jsonDecode(str.trim());
      if (m['app'] == 'miapara_master_v8') {
        await _db!.execute('CREATE TABLE IF NOT EXISTS members (id INTEGER PRIMARY KEY AUTOINCREMENT, book_sl INTEGER, name TEXT, phone TEXT, address TEXT DEFAULT "", monthly_rate INTEGER, member_type TEXT DEFAULT "MONTHLY", status TEXT DEFAULT "ACTIVE")');
        await _db!.execute('CREATE TABLE IF NOT EXISTS collections (id INTEGER PRIMARY KEY AUTOINCREMENT, member_id INTEGER, year INTEGER, month INTEGER, amount INTEGER, receipt_no TEXT, date TEXT, type TEXT, note TEXT)');
        await _db!.execute('CREATE TABLE IF NOT EXISTS cashbook (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, category TEXT, amount INTEGER, payment_method TEXT, voucher_no TEXT, date TEXT, note TEXT)');
        await _db!.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)');
        await _db!.execute('CREATE TABLE IF NOT EXISTS custom_categories (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, name TEXT UNIQUE)');
        await _db!.execute('CREATE TABLE IF NOT EXISTS cashbook_items (id INTEGER PRIMARY KEY AUTOINCREMENT, cashbook_id INTEGER, title TEXT, amount INTEGER, date TEXT)');

        await _db!.delete('members');
        await _db!.delete('collections');
        await _db!.delete('cashbook');
        // ব্যাকআপ রিস্টোর করলেও এই ফোনের Telegram credentials অক্ষত থাকবে।
        await _db!.delete(
          'settings',
          where: 'key NOT IN (?, ?)',
          whereArgs: ['telegram_bot_token', 'telegram_chat_id'],
        );
        await _db!.delete('custom_categories');
        await _db!.delete('cashbook_items');

        if (m['members'] != null) {
          const mCols = {'id', 'book_sl', 'name', 'phone', 'address', 'monthly_rate', 'member_type', 'status'};
          for (var r in m['members']) {
            final row = Map<String, dynamic>.from(r)..removeWhere((k, v) => !mCols.contains(k));
            await _db!.insert('members', row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        if (m['collections'] != null) {
          const cCols = {'id', 'member_id', 'year', 'month', 'amount', 'receipt_no', 'date', 'type', 'note'};
          for (var r in m['collections']) {
            final row = Map<String, dynamic>.from(r)..removeWhere((k, v) => !cCols.contains(k));
            await _db!.insert('collections', row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        if (m['cashbook'] != null) {
          const cbCols = {'id', 'type', 'category', 'amount', 'payment_method', 'voucher_no', 'date', 'note'};
          for (var r in m['cashbook']) {
            final row = Map<String, dynamic>.from(r)..removeWhere((k, v) => !cbCols.contains(k));
            await _db!.insert('cashbook', row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        if (m['settings'] != null) {
          const sCols = {'key', 'value'};
          for (var r in m['settings']) {
            final row = Map<String, dynamic>.from(r)..removeWhere((k, v) => !sCols.contains(k));
            await _db!.insert('settings', row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        if (m['cashbook_items'] != null) {
          for (var r in m['cashbook_items']) {
            await _db!.insert('cashbook_items', Map<String, dynamic>.from(r), conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        if (m['custom_categories'] != null) {
          for (var r in m['custom_categories']) {
            await _db!.insert('custom_categories', Map<String, dynamic>.from(r), conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        _refresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('আলহামদুলিল্লাহ! সকল ডাটা সফলভাবে রিস্টোর হয়েছে!')),
          );
        }
      } else {
        throw 'ব্যাকআপ ফাইলের ভার্সন মেলেনি।';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('রিস্টোর করতে সমস্যা: $e')),
        );
      }
    }
  }

  List<int> _buildPdfFromRgb(int width, int height, Uint8List rgbBytes) {
    final compressed = zlib.encode(rgbBytes);
    final buffer = BytesBuilder();
    final offsets = <int>[];

    void writeString(String s) { buffer.add(utf8.encode(s)); }

    writeString('%PDF-1.4\n%\xFF\xFF\xFF\xFF\n');

    offsets.add(buffer.length);
    writeString('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

    offsets.add(buffer.length);
    writeString('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');

    const double pageW = 595.0;
    const double pageH = 842.0;
    const double margin = 20.0;
    const double maxW = pageW - (margin * 2);
    const double maxH = pageH - (margin * 2);

    double scaleW = maxW / width;
    double scaleH = maxH / height;
    double scale = scaleW < scaleH ? scaleW : scaleH;

    double drawW = width * scale;
    double drawH = height * scale;
    double posX = margin + (maxW - drawW) / 2;
    double posY = margin + (maxH - drawH) / 2;

    offsets.add(buffer.length);
    writeString('3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageW.toInt()} ${pageH.toInt()}] /Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n');

    offsets.add(buffer.length);
    writeString('4 0 obj\n<< /Type /XObject /Subtype /Image /Width $width /Height $height /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ${compressed.length} >>\nstream\n');
    buffer.add(compressed);
    writeString('\nendstream\nendobj\n');

    final content = 'q ${drawW.toStringAsFixed(2)} 0 0 ${drawH.toStringAsFixed(2)} ${posX.toStringAsFixed(2)} ${posY.toStringAsFixed(2)} cm /Im1 Do Q';
    final contentBytes = utf8.encode(content);
    offsets.add(buffer.length);
    writeString('5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n$content\nendstream\nendobj\n');

    final startXref = buffer.length;
    writeString('xref\n0 6\n');
    writeString('0000000000 65535 f \n');
    for (var offset in offsets) {
      writeString('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }

    writeString('trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$startXref\n%%EOF');
    return buffer.toBytes();
  }

  Future<void> _exportBoundaryToPdf(GlobalKey key, String fileName, BuildContext ctx, String successMsg) async {
    try {
      RenderRepaintBoundary? b = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (b == null) return;
      ui.Image img = await b.toImage(pixelRatio: 2.5);
      ByteData? bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return;

      final width = img.width;
      final height = img.height;
      final totalPixels = width * height;
      final rgbBytes = Uint8List(totalPixels * 3);
      final rgba = bd.buffer.asUint8List();

      int rgbIdx = 0;
      int rgbaIdx = 0;
      for (int i = 0; i < totalPixels; i++) {
        rgbBytes[rgbIdx++] = rgba[rgbaIdx];
        rgbBytes[rgbIdx++] = rgba[rgbaIdx + 1];
        rgbBytes[rgbIdx++] = rgba[rgbaIdx + 2];
        rgbaIdx += 4;
      }

      final pdfBytes = _buildPdfFromRgb(width, height, rgbBytes);
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) {
        final file = File('${dir.path}/$fileName.pdf');
        await file.writeAsBytes(pdfBytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMsg)));
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF ডাউনলোডে সমস্যা হয়েছে!')));
      }
    }
  }
void _addMember({Map<String, dynamic>? member}) {
    final slC = TextEditingController(text: member?['book_sl']?.toString() ?? '');
    final nC = TextEditingController(text: member?['name'] ?? '');
    final pC = TextEditingController(text: member?['phone'] ?? '');
    final addressC = TextEditingController(text: member?['address'] ?? '');
    String type = member?['member_type'] ?? 'MONTHLY', st = member?['status'] ?? 'ACTIVE';
    final rC = TextEditingController(text: member != null ? ((type == 'YEARLY' ? member['monthly_rate'] * 12 : member['monthly_rate']) ~/ 100).toString() : '200');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text(member == null ? 'নতুন সদস্য' : 'তথ্য পরিবর্তন'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: slC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'ক্রমিক নম্বর (বাধ্যতামূলক)')),
                TextField(controller: nC, decoration: const InputDecoration(labelText: 'নাম (বাধ্যতামূলক)')),
                TextField(controller: pC, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'মোবাইল নম্বর')),
                TextField(controller: addressC, maxLines: 2, decoration: const InputDecoration(labelText: 'ঠিকানা (শুধু বিস্তারিত পেজে দেখাবে)')),
                DropdownButtonFormField<String>(
                  value: type, decoration: const InputDecoration(labelText: 'ধরন'),
                  items: const [DropdownMenuItem(value: 'MONTHLY', child: Text('মাসিক')), DropdownMenuItem(value: 'YEARLY', child: Text('বাৎসরিক'))],
                  onChanged: (v) => setD(() { type = v!; if (member == null) rC.text = type == 'YEARLY' ? '2400' : '200'; }),
                ),
                if (member != null) DropdownButtonFormField<String>(
                  value: st, decoration: const InputDecoration(labelText: 'অবস্থা'),
                  items: const [DropdownMenuItem(value: 'ACTIVE', child: Text('সক্রিয়')), DropdownMenuItem(value: 'RELOCATED', child: Text('স্থানান্তরিত')), DropdownMenuItem(value: 'DECEASED', child: Text('মরহুম')), DropdownMenuItem(value: 'CLOSED', child: Text('ফাঁকা/বন্ধ'))],
                  onChanged: (v) => setD(() => st = v!),
                ),
                TextField(controller: rC, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: type == 'YEARLY' ? 'বাৎসরিক চাঁদা (টাকা)' : 'মাসিক চাঁদা (টাকা)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                if (nC.text.trim().isEmpty) return;
                int bSl = int.tryParse(slC.text) ?? (_members.length + 1);
                int mR = type == 'YEARLY' ? ((int.tryParse(rC.text) ?? 2400) * 100 ~/ 12) : ((int.tryParse(rC.text) ?? 200) * 100);
                if (member == null) {
                  await _db!.insert('members', {'book_sl': bSl, 'name': nC.text.trim(), 'phone': pC.text.trim(), 'address': addressC.text.trim(), 'monthly_rate': mR, 'member_type': type, 'status': st});
                } else {
                  await _db!.update('members', {'book_sl': bSl, 'name': nC.text.trim(), 'phone': pC.text.trim(), 'address': addressC.text.trim(), 'monthly_rate': mR, 'member_type': type, 'status': st}, where: 'id=?', whereArgs: [member['id']]);
                }
                Navigator.pop(ctx);
                _refresh();
              },
              child: const Text('সংরক্ষণ'),
            ),
          ],
        ),
      ),
    );
  }

  void _collectFee(Map<String, dynamic> member, bool isRange, {int? targetMonth, int? targetYear}) {
    int sM = targetMonth ?? _cMonth, sY = targetYear ?? _cYear, eM = targetMonth ?? _cMonth, eY = targetYear ?? _cYear;
    int rate = member['monthly_rate'] as int;
    final rC = TextEditingController(), aC = TextEditingController(text: (rate ~/ 100).toString()), nC = TextEditingController();
    String method = 'CASH';
    DateTime selectedDate = DateTime.now();
    int count() => (!isRange) ? 1 : ((eY * 12 + eM) >= (sY * 12 + sM) ? (eY * 12 + eM) - (sY * 12 + sM) + 1 : 0);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) {
          int cnt = count();
          void chg() { int c = count(); if (c > 0) aC.text = ((rate * c) ~/ 100).toString(); setD(() {}); }
          return AlertDialog(
            title: Text('${member['name']} — চাঁদা জমা'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2035),
                      );
                      if (picked != null) {
                        setD(() => selectedDate = picked);
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.teal.shade300),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.calendar_month, size: 18, color: Colors.teal),
                              const SizedBox(width: 8),
                              Text(
                                'টাকা জমার তারিখ: ${BHelper.toBn(selectedDate.day)}/${BHelper.toBn(selectedDate.month)}/${BHelper.toBn(selectedDate.year)}',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal),
                              ),
                            ],
                          ),
                          const Icon(Icons.edit_calendar, size: 18, color: Colors.teal),
                        ],
                      ),
                    ),
                  ),

                  Row(children: [
                    Expanded(child: DropdownButtonFormField<int>(value: sM, decoration: InputDecoration(labelText: isRange ? 'শুরুর মাস' : 'মাস'), items: List.generate(12, (i) => i + 1).map((m) => DropdownMenuItem(value: m, child: Text(BHelper.mNames[m]))).toList(), onChanged: (v) { sM = v!; chg(); })),
                    const SizedBox(width: 6),
                    Expanded(child: DropdownButtonFormField<int>(value: sY, decoration: InputDecoration(labelText: isRange ? 'শুরুর সাল' : 'সাল'), items: List.generate(7, (i) => _cYear - 2 + i).map((y) => DropdownMenuItem(value: y, child: Text(BHelper.toBn(y)))).toList(), onChanged: (v) { sY = v!; chg(); })),
                  ]),
                  if (isRange) ...[
                    Row(children: [
                      Expanded(child: DropdownButtonFormField<int>(value: eM, decoration: const InputDecoration(labelText: 'শেষ মাস'), items: List.generate(12, (i) => i + 1).map((m) => DropdownMenuItem(value: m, child: Text(BHelper.mNames[m]))).toList(), onChanged: (v) { eM = v!; chg(); })),
                      const SizedBox(width: 6),
                      Expanded(child: DropdownButtonFormField<int>(value: eY, decoration: const InputDecoration(labelText: 'শেষ সাল'), items: List.generate(7, (i) => _cYear - 2 + i).map((y) => DropdownMenuItem(value: y, child: Text(BHelper.toBn(y)))).toList(), onChanged: (v) { eY = v!; chg(); })),
                    ]),
                    Text(cnt > 0 ? 'মেয়াদ: ${BHelper.toBn(cnt)} মাস' : 'ভুল তারিখ!', style: TextStyle(fontWeight: FontWeight.bold, color: cnt > 0 ? Colors.teal : Colors.red)),
                  ],
                  DropdownButtonFormField<String>(
                    value: method, decoration: const InputDecoration(labelText: 'মাধ্যম'),
                    items: const [DropdownMenuItem(value: 'CASH', child: Text('নগদ ক্যাশ')), DropdownMenuItem(value: 'BANK', child: Text('ব্যাংক একাউন্ট'))],
                    onChanged: (v) => setD(() => method = v!),
                  ),
                  TextField(controller: rC, decoration: const InputDecoration(labelText: 'কাগজের রসিদ নং (যেমন: ১০৫৪)')),
                  TextField(controller: aC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'টাকার পরিমাণ')),
                  TextField(controller: nC, decoration: const InputDecoration(labelText: 'মন্তব্য (ঐচ্ছিক)')),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white),
                onPressed: () async {
                  if (cnt <= 0) return;
                  int tk = int.tryParse(aC.text) ?? 0;
                  if (tk <= 0) return;
                  String rNo = rC.text.trim().isEmpty ? 'RCP-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}' : rC.text.trim();
                  int sTot = sY * 12 + (sM - 1), eTot = (!isRange) ? sTot : eY * 12 + (eM - 1), share = (tk * 100) ~/ cnt;
                  
                  final entryDate = DateTime(selectedDate.year, selectedDate.month, selectedDate.day, 12, 0).toIso8601String();
                  for (int c = sTot; c <= eTot; c++) {
                    await _db!.insert('collections', {'member_id': member['id'], 'year': c ~/ 12, 'month': (c % 12) + 1, 'amount': share, 'receipt_no': rNo, 'date': entryDate, 'type': isRange ? 'RANGE' : 'MONTHLY', 'note': nC.text.trim()});
                  }
                  String pTx = !isRange ? '${BHelper.mNames[sM]} $sY' : '${BHelper.mNames[sM]} $sY হতে ${BHelper.mNames[eM]} $eY ($cnt মাস)';
                  await _db!.insert('cashbook', {'type': 'INCOME', 'category': 'মাসিক চাঁদা', 'amount': tk * 100, 'payment_method': method, 'voucher_no': rNo, 'date': entryDate, 'note': '${member['name']} — $pTx'});
                  Navigator.pop(ctx);
                  _refresh();
                  _showReceipt(member['name'].toString(), member['phone'], tk * 100, rNo, pTx);
                },
                child: const Text('জমা ও রসিদ'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _editCollection(Map<String, dynamic> member, Map<String, dynamic> h) {
    final aC = TextEditingController(text: ((h['amount'] as int) ~/ 100).toString());
    final rC = TextEditingController(text: h['receipt_no'].toString());
    final nC = TextEditingController(text: (h['note'] ?? '').toString());
    DateTime eDate = DateTime.tryParse(h['date'].toString()) ?? DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text('${member['name']} — এন্ট্রি সংশোধন'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('মাস: ${BHelper.mNames[h['month'] as int]} ${BHelper.toBn(h['year'])}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: eDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (picked != null) {
                      setD(() => eDate = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.teal.shade300)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.calendar_month, size: 18, color: Colors.teal),
                            const SizedBox(width: 8),
                            Text('জমার তারিখ: ${BHelper.toBn(eDate.day)}/${BHelper.toBn(eDate.month)}/${BHelper.toBn(eDate.year)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal)),
                          ],
                        ),
                        const Icon(Icons.edit_calendar, size: 18, color: Colors.teal),
                      ],
                    ),
                  ),
                ),
                TextField(controller: aC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'টাকার পরিমাণ')),
                TextField(controller: rC, decoration: const InputDecoration(labelText: 'রসিদ নং')),
                TextField(controller: nC, decoration: const InputDecoration(labelText: 'মন্তব্য')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white),
              onPressed: () async {
                int newTk = int.tryParse(aC.text) ?? 0;
                if (newTk <= 0) return;
                final newDateStr = DateTime(eDate.year, eDate.month, eDate.day, 12, 0).toIso8601String();
                final oldReceipt = h['receipt_no'].toString();
                final newReceipt = rC.text.trim().isEmpty ? oldReceipt : rC.text.trim();

                await _db!.update('collections', {
                  'amount': newTk * 100,
                  'receipt_no': newReceipt,
                  'date': newDateStr,
                  'note': nC.text.trim(),
                }, where: 'id=?', whereArgs: [h['id']]);

                await _db!.update('cashbook', {
                  'amount': newTk * 100,
                  'voucher_no': newReceipt,
                  'date': newDateStr,
                  'note': '${member['name']} — ${BHelper.mNames[h['month'] as int]} ${h['year']}',
                }, where: 'voucher_no=?', whereArgs: [oldReceipt]);

                Navigator.pop(ctx);
                _refresh();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('এন্ট্রি সফলভাবে সংশোধন হয়েছে!')));
                }
              },
              child: const Text('আপডেট'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMonthDetailsDialog(Map<String, dynamic> member, int month, int year, List<Map<String, dynamic>> entries) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${BHelper.mNames[month]} ${BHelper.toBn(year)} — জমার বিবরণ'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: entries.map((h) {
              final pText = '${BHelper.mNames[month]} ${BHelper.toBn(year)}';
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('জমা: ${BHelper.taka(h['amount'] as int)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.teal)),
                        Text('রসিদ: ${h['receipt_no']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text('তারিখ: ${h['date'].toString().substring(0, 10)}', style: const TextStyle(fontSize: 10, color: Colors.black54)),
                    if (h['note'] != null && h['note'].toString().isNotEmpty)
                      Text('মন্তব্য: ${h['note']}', style: const TextStyle(fontSize: 10, color: Colors.black87)),
                    const Divider(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.picture_as_pdf, size: 16, color: Colors.teal),
                          label: const Text('রশিদ PDF', style: TextStyle(fontSize: 11, color: Colors.teal)),
                          onPressed: () {
                            _showReceipt(member['name'].toString(), member['phone'], h['amount'] as int, h['receipt_no'].toString(), pText);
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.edit, size: 16, color: Colors.blueAccent),
                          label: const Text('এডিট', style: TextStyle(fontSize: 11, color: Colors.blueAccent)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _editCollection(member, h);
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                          label: const Text('মুছুন', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (delCtx) => AlertDialog(
                                title: const Text('এন্ট্রি মুছে ফেলবেন?'),
                                content: Text('$pText এর ${BHelper.taka(h['amount'] as int)} জমার এন্ট্রিটি কি নিশ্চিত মুছে ফেলতে চান?\n(এটি ক্যাশবুক থেকেও বাদ হয়ে যাবে)'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text('না, রাখুন')),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800], foregroundColor: Colors.white),
                                    onPressed: () async {
                                      await _db!.delete('collections', where: 'id=?', whereArgs: [h['id']]);
                                      await _db!.delete('cashbook', where: 'voucher_no=?', whereArgs: [h['receipt_no']]);
                                      Navigator.pop(delCtx);
                                      Navigator.pop(ctx);
                                      _refresh();
                                    },
                                    child: const Text('হ্যাঁ, মুছুন'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বন্ধ')),
        ],
      ),
    );
  }

  void _openPassbook(Map<String, dynamic> m) async {
    final mId = m['id'] as int, rate = m['monthly_rate'] as int, isY = m['member_type'] == 'YEARLY';
    final yCollections = await _db!.rawQuery(
      "SELECT * FROM collections WHERE member_id=? AND year=? ORDER BY id DESC",
      [mId, _cYear],
    );

    Map<int, List<Map<String, dynamic>>> mCollections = {};
    Map<int, int> mMap = {};
    for (var r in yCollections) {
      int mo = r['month'] as int;
      mCollections.putIfAbsent(mo, () => []).add(r);
      mMap[mo] = (mMap[mo] ?? 0) + ((r['amount'] as int));
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.82, padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10)))),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('নং ${BHelper.toBn(m['book_sl'] ?? m['id'])}। ${m['name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.edit, size: 18, color: Colors.teal), onPressed: () => _addMember(member: m)),
                ]),
                Text('মোবাইল: ${BHelper.toBn(m['phone'] ?? "নেই")} | চাঁদা: ${BHelper.taka(isY ? rate * 12 : rate)}${isY ? "/বছর" : "/মাস"}', style: TextStyle(color: Colors.grey[700], fontSize: 12)),
                if ((m['address'] ?? '').toString().trim().isNotEmpty)
                  Text('ঠিকানা: ${m['address']}', style: TextStyle(color: Colors.grey[700], fontSize: 12)),
              ])),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
            ]),
            Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.teal.shade200)),
              child: Row(children: [
                const Icon(Icons.verified, color: Colors.teal, size: 16), const SizedBox(width: 6),
                Expanded(child: Text(m['lp_text'], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal))),
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: Colors.teal[900]),
                  icon: const Icon(Icons.send, size: 14), label: const Text('তাগাদা মেসেজ', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    final msg = 'আসসালামু আলাইকুম ${m['name']} ভাই। মিয়াপাড়া কেন্দ্রীয় জামে মসজিদে আপনার চাঁদা ${m['lp_text']}। সময়মতো চাঁদাটি দিয়ে মসজিদ পরিচালনায় সহায়তার অনুরোধ রইল। আল্লাহ বরকত দিন।';
                    Clipboard.setData(ClipboardData(text: msg));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('সম্মানজনক তাগাদা মেসেজ কপি হয়েছে!')));
                  },
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white), icon: const Icon(Icons.calendar_today, size: 14), label: const Text('এক মাস জমা', style: TextStyle(fontSize: 11)), onPressed: () { Navigator.pop(ctx); _collectFee(m, false); })),
              const SizedBox(width: 5),
              Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[800], foregroundColor: Colors.white), icon: const Icon(Icons.date_range, size: 14), label: const Text('মেয়াদী জমা', style: TextStyle(fontSize: 11)), onPressed: () { Navigator.pop(ctx); _collectFee(m, true); })),
            ]),
            const Divider(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${BHelper.toBn(_cYear)} সালের ১২ মাসের খাতা:', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.teal)),
                const Text('(বক্সে ট্যাপ করে জমা দিন বা রশিদ দেখুন)', style: TextStyle(fontSize: 10, color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 1.25,
                ),
                itemCount: 12,
                itemBuilder: (context, idx) {
                  final mo = idx + 1;
                  final p = mMap[mo] ?? 0;
                  final isP = p >= rate;
                  final entries = mCollections[mo] ?? [];

                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      if (entries.isNotEmpty) {
                        _showMonthDetailsDialog(m, mo, _cYear, entries);
                      } else {
                        Navigator.pop(ctx);
                        _collectFee(m, false, targetMonth: mo, targetYear: _cYear);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      decoration: BoxDecoration(
                        color: isP ? Colors.green.shade50 : (p > 0 ? Colors.orange.shade50 : Colors.red.shade50),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isP ? Colors.green.shade600 : (p > 0 ? Colors.orange.shade600 : Colors.red.shade300),
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(BHelper.mNames[mo], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            isP ? 'পরিশোধ' : (p > 0 ? BHelper.taka(p) : 'বকেয়া'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isP ? Colors.green.shade800 : (p > 0 ? Colors.orange.shade900 : Colors.red.shade900),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(isP ? Icons.receipt_long : Icons.add_circle_outline, size: 10, color: isP ? Colors.green.shade700 : Colors.red.shade700),
                              const SizedBox(width: 2),
                              Text(isP ? 'রশিদ দেখুন' : 'জমা নিন', style: TextStyle(fontSize: 9, color: isP ? Colors.green.shade700 : Colors.red.shade700)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showReceipt(String name, dynamic phone, int amt, String rNo, String pText) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: EdgeInsets.zero,
        content: RepaintBoundary(
          key: _receiptKey,
          child: Container(
            width: 330, padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.teal.shade800, width: 2)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.teal)),
                const Text('চাঁদা আদায় রসিদ', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const Divider(),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('রসিদ: $rNo', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)), Text('তারিখ: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}', style: const TextStyle(fontSize: 10))]),
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerLeft, child: Text('চাঁদাদাতা: $name', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                if (phone != null && phone.toString().isNotEmpty) Align(alignment: Alignment.centerLeft, child: Text('মোবাইল: ${BHelper.toBn(phone)}', style: const TextStyle(fontSize: 10))),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity, padding: const EdgeInsets.all(8), color: Colors.teal.shade50,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('বিবরণ: $pText', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)), const SizedBox(height: 2), Text('মোট জমা: ${BHelper.taka(amt)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.teal))]),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বন্ধ')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white),
            icon: const Icon(Icons.picture_as_pdf, size: 14), label: const Text('PDF ডাউনলোড'),
            onPressed: () => _exportBoundaryToPdf(_receiptKey, 'Miapara_Receipt_$rNo', context, 'রশিদ PDF Download ফোল্ডারে সেভ হয়েছে!'),
          ),
        ],
      ),
    );
  }
void _showAddCategoryDialog(bool isInc, Function(String) onAdded) {
    final cCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isInc ? 'নতুন আয়ের খাত যোগ করুন' : 'নতুন ব্যয়ের খাত যোগ করুন'),
        content: TextField(
          controller: cCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'খাতের নাম লিখুন...',
            labelText: 'খাত',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final name = cCtrl.text.trim();
              if (name.isEmpty) return;
              try {
                await _db!.insert(
                  'custom_categories',
                  {'type': isInc ? 'INCOME' : 'EXPENSE', 'name': name},
                  conflictAlgorithm: ConflictAlgorithm.ignore,
                );
                onAdded(name);
                Navigator.pop(ctx);
                _refresh();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('নতুন খাত "$name" যোগ হয়েছে!')));
                }
              } catch (_) {}
            },
            child: const Text('যোগ করুন'),
          ),
        ],
      ),
    );
  }

  void _showCashbookDetails(Map<String, dynamic> e) async {
    final cId = e['id'] as int;
    final isInc = e['type'] == 'INCOME';

    final items = await _db!.query('cashbook_items', where: 'cashbook_id=?', whereArgs: [cId], orderBy: 'id ASC');

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModal) => Container(
          height: MediaQuery.of(context).size.height * 0.85,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e['category'], style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('ভাউচার/রসিদ নং: ${e['voucher_no'] != null && e['voucher_no'] != '' ? e['voucher_no'] : "নেই"} | মাধ্যম: ${e['payment_method'] == "BANK" ? "ব্যাংক" : "নগদ"}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                  Text(
                    '${isInc ? "+ " : "- "}${BHelper.taka(e['amount'] as int)}',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isInc ? Colors.green[800] : Colors.red[800]),
                  ),
                ],
              ),
              const Divider(height: 14),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('আইটেম / খরচের বিস্তারিত বিবরণ:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isInc ? Colors.teal[800] : Colors.red[800],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    ),
                    icon: const Icon(Icons.add, size: 14),
                    label: Text(isInc ? 'টাকা/কিস্তি যোগ' : 'খরচ/আইটেম যোগ', style: const TextStyle(fontSize: 11)),
                    onPressed: () => _showAddItemDialog(e, () {
                      Navigator.pop(ctx);
                      _refresh();
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              Expanded(
                child: items.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          e['note'] != null && e['note'].toString().isNotEmpty
                              ? 'বিবরণ: ${e['note']}'
                              : 'এই ভাউচারে আলাদা কোনো আইটেম যোগ করা হয়নি। উপরের বাটন দিয়ে যেকোনো সময় নতুন খরচ বা কিস্তি যোগ করতে পারেন।',
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (c, idx) {
                          final it = items[idx];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(it['title'].toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            subtitle: Text('তারিখ: ${it['date'].toString().substring(0, 10)}', style: const TextStyle(fontSize: 10)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(BHelper.taka(it['amount'] as int), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isInc ? Colors.green[800] : Colors.red[800])),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                  onPressed: () async {
                                    await _db!.delete('cashbook_items', where: 'id=?', whereArgs: [it['id']]);
                                    final sumQ = await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook_items WHERE cashbook_id=?", [cId]);
                                    int newTot = (sumQ.first['s'] as int);
                                    await _db!.update('cashbook', {'amount': newTot}, where: 'id=?', whereArgs: [cId]);
                                    Navigator.pop(ctx);
                                    _refresh();
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),

              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    icon: const Icon(Icons.delete_forever, size: 18),
                    label: const Text('সম্পূর্ণ ভাউচার ডিলিট'),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (delCtx) => AlertDialog(
                          title: const Text('ভাউচার মুছে ফেলবেন?'),
                          content: Text('আপনি কি নিশ্চিত "${e['category']}" এর সম্পূর্ণ ভাউচার এবং এর সকল খরচ/আয় মুছে ফেলতে চান?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text('না, রাখুন')),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800], foregroundColor: Colors.white),
                              onPressed: () async {
                                await _db!.delete('cashbook', where: 'id=?', whereArgs: [cId]);
                                await _db!.delete('cashbook_items', where: 'cashbook_id=?', whereArgs: [cId]);
                                Navigator.pop(delCtx);
                                Navigator.pop(ctx);
                                _refresh();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ভাউচার মুছে ফেলা হয়েছে!')));
                                }
                              },
                              child: const Text('হ্যাঁ, মুছুন'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('বন্ধ'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddItemDialog(Map<String, dynamic> e, VoidCallback onSaved) {
    final titleC = TextEditingController();
    final amtC = TextEditingController();
    DateTime itemDate = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text(e['type'] == 'INCOME' ? 'নতুন টাকা / কিস্তি যোগ' : 'নতুন খরচ / আইটেম যোগ'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: itemDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (picked != null) {
                      setD(() => itemDate = picked);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.teal.shade300)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.calendar_month, size: 16, color: Colors.teal),
                            const SizedBox(width: 8),
                            Text(
                              'তারিখ: ${BHelper.toBn(itemDate.day)}/${BHelper.toBn(itemDate.month)}/${BHelper.toBn(itemDate.year)}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal),
                            ),
                          ],
                        ),
                        const Icon(Icons.edit_calendar, size: 16, color: Colors.teal),
                      ],
                    ),
                  ),
                ),
                TextField(
                  controller: titleC,
                  decoration: InputDecoration(
                    labelText: e['type'] == 'INCOME' ? 'বিবরণ (যেমন: দোকান ২ ভাড়া)' : 'কাজের নাম / পণ্য (যেমন: রাজমিস্ত্রি মজুরি)',
                  ),
                ),
                TextField(
                  controller: amtC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'টাকার পরিমাণ'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: e['type'] == 'INCOME' ? Colors.teal[800] : Colors.red[800], foregroundColor: Colors.white),
              onPressed: () async {
                final t = titleC.text.trim();
                final amt = (int.tryParse(amtC.text) ?? 0) * 100;
                if (t.isEmpty || amt <= 0) return;

                final cId = e['id'] as int;
                final existingItems = await _db!.query('cashbook_items', where: 'cashbook_id=?', whereArgs: [cId]);

                if (existingItems.isEmpty && (e['amount'] as int) > 0) {
                  await _db!.insert('cashbook_items', {
                    'cashbook_id': cId,
                    'title': e['note'] != null && e['note'].toString().isNotEmpty ? e['note'] : e['category'],
                    'amount': e['amount'],
                    'date': e['date'],
                  });
                }

                await _db!.insert('cashbook_items', {
                  'cashbook_id': cId,
                  'title': t,
                  'amount': amt,
                  'date': DateTime(itemDate.year, itemDate.month, itemDate.day, 12, 0).toIso8601String(),
                });

                final sumQ = await _db!.rawQuery("SELECT COALESCE(SUM(amount),0) as s FROM cashbook_items WHERE cashbook_id=?", [cId]);
                int newTotal = (sumQ.first['s'] as int);
                await _db!.update('cashbook', {'amount': newTotal}, where: 'id=?', whereArgs: [cId]);

                Navigator.pop(ctx);
                onSaved();
              },
              child: const Text('সংরক্ষণ'),
            ),
          ],
        ),
      ),
    );
  }

  void _addCashbook(bool isInc) {
    String cat = isInc ? _inCats.first : _outCats.first;
    String method = 'CASH';
    final aC = TextEditingController(), vC = TextEditingController(), nC = TextEditingController();
    DateTime entryDate = DateTime.now();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text(isInc ? 'আয় যোগ' : 'ব্যয় / ভাউচার'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: entryDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (picked != null) {
                      setD(() => entryDate = picked);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: isInc ? Colors.teal.shade50 : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: isInc ? Colors.teal.shade300 : Colors.red.shade300),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.calendar_month, size: 18, color: isInc ? Colors.teal : Colors.red),
                            const SizedBox(width: 8),
                            Text(
                              'তারিখ: ${BHelper.toBn(entryDate.day)}/${BHelper.toBn(entryDate.month)}/${BHelper.toBn(entryDate.year)}',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isInc ? Colors.teal : Colors.red),
                            ),
                          ],
                        ),
                        Icon(Icons.edit_calendar, size: 18, color: isInc ? Colors.teal : Colors.red),
                      ],
                    ),
                  ),
                ),

                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: (isInc ? _inCats : _outCats).contains(cat) ? cat : (isInc ? _inCats.first : _outCats.first),
                        decoration: InputDecoration(labelText: isInc ? 'আয়ের খাত' : 'ব্যয়ের খাত'),
                        isExpanded: true,
                        items: (isInc ? _inCats : _outCats).map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis))).toList(),
                        onChanged: (v) => setD(() => cat = v!),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add_circle, color: isInc ? Colors.teal : Colors.red),
                      tooltip: 'নতুন খাত যোগ করুন',
                      onPressed: () => _showAddCategoryDialog(isInc, (newCat) {
                        setD(() {
                          cat = newCat;
                        });
                      }),
                    ),
                  ],
                ),

                DropdownButtonFormField<String>(
                  value: method, decoration: const InputDecoration(labelText: 'মাধ্যম'),
                  items: const [DropdownMenuItem(value: 'CASH', child: Text('নগদ ক্যাশ')), DropdownMenuItem(value: 'BANK', child: Text('ব্যাংক একাউন্ট'))],
                  onChanged: (v) => setD(() => method = v!),
                ),
                TextField(controller: aC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'টাকার পরিমাণ')),
                TextField(controller: vC, decoration: InputDecoration(labelText: isInc ? 'রসিদ নং (ঐচ্ছিক)' : 'ভাউচার নং (বাধ্যতামূলক)')),
                TextField(controller: nC, decoration: InputDecoration(labelText: isInc ? 'বিবরণ (যেমন: দোকান ১ ভাড়া)' : 'প্রথম কাজের নাম / বিবরণ (যেমন: সিমেন্ট কেনা)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: isInc ? Colors.teal[800] : Colors.red[800], foregroundColor: Colors.white),
              onPressed: () async {
                int tk = int.tryParse(aC.text) ?? 0;
                if (tk <= 0) return;
                final dateStr = DateTime(entryDate.year, entryDate.month, entryDate.day, 12, 0).toIso8601String();
                
                int insId = await _db!.insert('cashbook', {
                  'type': isInc ? 'INCOME' : 'EXPENSE',
                  'category': cat,
                  'amount': tk * 100,
                  'payment_method': method,
                  'voucher_no': vC.text.trim(),
                  'date': dateStr,
                  'note': nC.text.trim(),
                });

                if (nC.text.trim().isNotEmpty) {
                  await _db!.insert('cashbook_items', {
                    'cashbook_id': insId,
                    'title': nC.text.trim(),
                    'amount': tk * 100,
                    'date': dateStr,
                  });
                }

                Navigator.pop(ctx);
                _refresh();
              },
              child: const Text('সংরক্ষণ'),
            ),
          ],
        ),
      ),
    );
  }

  void _addTransfer() {
    String type = 'CASH_TO_BANK';
    final aC = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('ক্যাশ ও ব্যাংক সমন্বয়'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: type, decoration: const InputDecoration(labelText: 'ধরন'),
                items: const [DropdownMenuItem(value: 'CASH_TO_BANK', child: Text('ক্যাশ থেকে ব্যাংকে জমা')), DropdownMenuItem(value: 'BANK_TO_CASH', child: Text('ব্যাংক থেকে ক্যাশ উত্তোলন'))],
                onChanged: (v) => setD(() => type = v!),
              ),
              TextField(controller: aC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'টাকার পরিমাণ')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            ElevatedButton(
              onPressed: () async {
                int tk = int.tryParse(aC.text) ?? 0;
                if (tk <= 0) return;
                await _db!.insert('cashbook', {'type': 'TRANSFER', 'category': type == 'CASH_TO_BANK' ? 'ক্যাশ হতে ব্যাংকে জমা' : 'ব্যাংক হতে ক্যাশ উত্তোলন', 'amount': tk * 100, 'payment_method': type, 'voucher_no': 'TRF', 'date': DateTime.now().toIso8601String(), 'note': ''});
                Navigator.pop(ctx);
                _refresh();
              },
              child: const Text('স্থানান্তর'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoBackupTimer?.cancel();
    _periodicAutoBackupTimer?.cancel();
    _pinCtrl.dispose();
    _sCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return Scaffold(
        backgroundColor: Colors.teal[900],
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.security, size: 56, color: Colors.amber),
              const SizedBox(height: 8),
              const Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const Text('পিন কোড দিন', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 10),
              Container(
                width: 160, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                child: TextField(controller: _pinCtrl, keyboardType: TextInputType.number, maxLength: 4, obscureText: true, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, letterSpacing: 6, fontWeight: FontWeight.bold), decoration: const InputDecoration(counterText: '', border: InputBorder.none, hintText: '••••')),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black87),
                onPressed: () { if (_pinCtrl.text.trim() == _pin) setState(() => _locked = false); },
                child: const Text('আনলক'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: TextStyle(fontSize: 15, color: Colors.white)),
        backgroundColor: Colors.teal[800],
        actions: [
          IconButton(
            icon: const Icon(Icons.lock_outline, color: Colors.white, size: 20),
            onPressed: () {
              final pC = TextEditingController(text: _pin);
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('পিন কোড সেট'),
                  content: TextField(controller: pC, keyboardType: TextInputType.number, maxLength: 4, obscureText: true, decoration: const InputDecoration(labelText: '৪ সংখ্যার পিন (মুছতে খালি রাখুন)')),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
                    ElevatedButton(onPressed: () async {
                      _pin = pC.text.trim();
                      await _db!.insert('settings', {'key': 'app_pin', 'value': _pin}, conflictAlgorithm: ConflictAlgorithm.replace);
                      Navigator.pop(ctx);
                    }, child: const Text('সেভ')),
                  ],
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.account_balance_wallet, color: Colors.amber, size: 20),
            onPressed: () {
              final cC = TextEditingController(text: (_opCash ~/ 100).toString());
              final bC = TextEditingController(text: (_opBank ~/ 100).toString());
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('শুরুর তহবিল নির্ধারণ'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(controller: cC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'পূর্বে ক্যাশে কত ছিল')),
                    TextField(controller: bC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'পূর্বে ব্যাংকে কত ছিল')),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
                    ElevatedButton(onPressed: () async {
                      await _db!.insert('settings', {'key': 'opening_cash', 'value': ((int.tryParse(cC.text) ?? 0) * 100).toString()}, conflictAlgorithm: ConflictAlgorithm.replace);
                      await _db!.insert('settings', {'key': 'opening_bank', 'value': ((int.tryParse(bC.text) ?? 0) * 100).toString()}, conflictAlgorithm: ConflictAlgorithm.replace);
                      Navigator.pop(ctx);
                      _refresh();
                    }, child: const Text('সেভ')),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab, selectedItemColor: Colors.teal[800],
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'চাঁদা খাতা'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance), label: 'ক্যাশ খাতা'),
          BottomNavigationBarItem(icon: Icon(Icons.analytics), label: 'অডিট ও ব্যাকআপ'),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _buildBody(),
    );
  }

  Widget _topBox(String t, String v, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: Colors.white.withAlpha(20), borderRadius: BorderRadius.circular(4)),
      child: Column(children: [Text(t, style: const TextStyle(fontSize: 9, color: Colors.white70)), Text(v, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: c))]),
    ),
  );

  Widget _buildBody() {
    if (_tab == 0) return _buildChandaTab();
    if (_tab == 1) return _buildCashbookTab();
    return _buildAuditTab();
  }

  Future<void> _showThisMonthPaidMembers() async {
    final monthKey = '$_cYear-${_cMonth.toString().padLeft(2, '0')}';
    final rows = await _db!.rawQuery(
      "SELECT m.id, m.book_sl, m.name, m.phone, SUM(c.amount) AS paid_amount, COUNT(c.id) AS entries "
      "FROM collections c INNER JOIN members m ON m.id = c.member_id "
      "WHERE substr(c.date,1,7)=? GROUP BY m.id, m.book_sl, m.name, m.phone "
      "ORDER BY m.book_sl ASC, m.id ASC",
      [monthKey],
    );
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${BHelper.mNames[_cMonth]} ${BHelper.toBn(_cYear)} — এই মাসে জমাদানকারী'),
        content: SizedBox(
          width: double.maxFinite,
          child: rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('এই মাসে এখনো কোনো সদস্যের চাঁদা জমা হয়নি।'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final r = rows[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 17,
                        child: Text(BHelper.toBn(r['book_sl'] ?? r['id']), style: const TextStyle(fontSize: 11)),
                      ),
                      title: Text((r['name'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      subtitle: Text('জমা এন্ট্রি: ${BHelper.toBn(r['entries'])}'),
                      trailing: Text(
                        BHelper.taka((r['paid_amount'] as int?) ?? 0),
                        style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বন্ধ')),
        ],
      ),
    );
  }

  Widget _buildChandaTab() {
    final filtered = _members.where((m) {
      final n = m['name'].toString().toLowerCase(), p = (m['phone'] ?? '').toString(), s = (m['book_sl'] ?? '').toString();
      final match = n.contains(_search.toLowerCase()) || p.contains(_search) || s.contains(_search);
      if (!match) return false;
      if (_mFilter == 'MONTHLY') return m['member_type'] == 'MONTHLY' && m['status'] != 'CLOSED';
      if (_mFilter == 'YEARLY') return m['member_type'] == 'YEARLY' && m['status'] != 'CLOSED';
      if (_mFilter == 'CLOSED') return m['status'] == 'CLOSED';
      if (_mFilter == 'ALL') return m['status'] != 'CLOSED';
      return true;
    }).toList();

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.teal[800], icon: const Icon(Icons.person_add, color: Colors.white, size: 16),
        label: const Text('নতুন সদস্য', style: TextStyle(color: Colors.white, fontSize: 12)),
        onPressed: () => _addMember(),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: Colors.white,
            child: _isSearchOpen
                ? Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: TextField(
                            controller: _sCtrl,
                            autofocus: true,
                            decoration: InputDecoration(
                              hintText: 'ক্রমিক, নাম বা মোবাইল দিয়ে খুঁজুন...',
                              hintStyle: const TextStyle(fontSize: 12),
                              prefixIcon: const Icon(Icons.search, size: 20, color: Colors.teal),
                              suffixIcon: _search.isNotEmpty
                                  ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _sCtrl.clear(); setState(() => _search = ''); })
                                  : null,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            onChanged: (v) => setState(() => _search = v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.redAccent),
                        onPressed: () {
                          setState(() {
                            _isSearchOpen = false;
                            _search = '';
                            _sCtrl.clear();
                          });
                        },
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _cChip('ALL', 'সকল (${BHelper.toBn(_members.where((m)=>m['status']!='CLOSED').length)})'),
                              const SizedBox(width: 6),
                              _cChip('MONTHLY', 'মাসিক (${BHelper.toBn(_members.where((m)=>m['member_type']=='MONTHLY' && m['status']!='CLOSED').length)})'),
                              const SizedBox(width: 6),
                              _cChip('YEARLY', 'বাৎসরিক (${BHelper.toBn(_members.where((m)=>m['member_type']=='YEARLY' && m['status']!='CLOSED').length)})'),
                              const SizedBox(width: 6),
                              _cChip('CLOSED', 'ফাঁকা/বন্ধ (${BHelper.toBn(_members.where((m)=>m['status']=='CLOSED').length)})'),
                            ],
                          ),
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.search, color: Colors.teal, size: 24), tooltip: 'খুঁজুন', onPressed: () => setState(() => _isSearchOpen = true)),
                    ],
                  ),
          ),
          
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), color: Colors.teal.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  IconButton(icon: const Icon(Icons.chevron_left, size: 22), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () { setState(() { if (_cMonth == 1) { _cMonth = 12; _cYear--; } else { _cMonth--; } }); _refresh(); }),
                  const SizedBox(width: 6),
                  Text('${BHelper.mNames[_cMonth]} ${BHelper.toBn(_cYear)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(width: 6),
                  IconButton(icon: const Icon(Icons.chevron_right, size: 22), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () { setState(() { if (_cMonth == 12) { _cMonth = 1; _cYear++; } else { _cMonth++; } }); _refresh(); }),
                ]),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _showThisMonthPaidMembers,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.teal.shade300)),
                    child: Text('নগদ আদায়: ${BHelper.taka(_mChanda)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal[900])),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, idx) {
                final m = filtered[idx];
                final isCov = m['covered'] as bool;
                final isY = m['member_type'] == 'YEARLY';
                final st = m['status'];
                final bSl = m['book_sl'] ?? (idx + 1);
                final paidThisMonth = m['paid_this_month'] as bool? ?? false;

                return ListTile(
                  dense: true, visualDensity: const VisualDensity(vertical: -1),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  onTap: () => _openPassbook(m),
                  leading: Container(
                    width: 44, height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: paidThisMonth ? Colors.green.shade100 : (isCov ? Colors.teal.shade100 : Colors.orange.shade100),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: paidThisMonth ? Colors.green.shade700 : (isCov ? Colors.teal.shade600 : Colors.orange.shade700),
                        width: 1.5,
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          BHelper.toBn(bSl),
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                            color: paidThisMonth ? Colors.green.shade900 : (isCov ? Colors.teal.shade900 : Colors.orange.shade900),
                          ),
                        ),
                      ),
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          m['name'],
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: paidThisMonth ? Colors.green.shade800 : Colors.black87,
                          ),
                        ),
                      ),
                      if (paidThisMonth)
                        Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.green.shade600)),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check, size: 10, color: Colors.green),
                              SizedBox(width: 2),
                              Text('এই মাসে আদায়', style: TextStyle(fontSize: 8, color: Colors.green, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      if (st != 'ACTIVE')
                        Container(margin: const EdgeInsets.only(left: 4), padding: const EdgeInsets.symmetric(horizontal: 4), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)), child: Text(st == 'RELOCATED' ? 'স্থানান্তরিত' : (st == 'CLOSED' ? 'ফাঁকা/বন্ধ' : 'মরহুম'), style: const TextStyle(fontSize: 9)))
                      else if (isY)
                        Container(margin: const EdgeInsets.only(left: 4), padding: const EdgeInsets.symmetric(horizontal: 4), decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(4)), child: const Text('বাৎসরিক', style: TextStyle(fontSize: 9, color: Colors.deepOrange, fontWeight: FontWeight.bold))),
                    ],
                  ),
                  subtitle: Text(
                    '${m['lp_text']} | ধার্য: ${BHelper.taka(isY ? (m['monthly_rate'] as int) * 12 : (m['monthly_rate'] as int))}${isY ? "/বছর" : "/মাস"}',
                    style: TextStyle(fontSize: 11, color: isCov ? Colors.teal[800] : Colors.orange[900]),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _cChip(String k, String l) => ChoiceChip(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    label: Text(l, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _mFilter == k ? Colors.white : Colors.teal[900])),
    selected: _mFilter == k, selectedColor: Colors.teal[800], showCheckmark: false,
    onSelected: (v) { if (v) setState(() => _mFilter = k); },
  );

  Widget _buildCashbookTab() {
    final filtered = _cashList.where((e) {
      if (_cFilter == 'INCOME') return e['type'] == 'INCOME';
      if (_cFilter == 'EXPENSE') return e['type'] == 'EXPENSE';
      if (_cFilter == 'TRANSFER') return e['type'] == 'TRANSFER';
      return true;
    }).toList();

    return Column(
      children: [
        Container(
          color: Colors.teal.shade900, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            _topBox('হাতে নগদ', BHelper.taka(_cash), Colors.amber),
            const SizedBox(width: 4),
            _topBox('ব্যাংক স্থিতি', BHelper.taka(_bank), Colors.lightBlueAccent),
            const SizedBox(width: 4),
            _topBox('মোট তহবিল', BHelper.taka(_cash + _bank), Colors.greenAccent),
          ]),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), color: Colors.teal.shade50,
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${BHelper.mNames[_cMonth]} ${BHelper.toBn(_cYear)} — ক্যাশবুক', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back, size: 18), onPressed: () { setState(() { if (_cMonth == 1) { _cMonth = 12; _cYear--; } else { _cMonth--; } }); _refresh(); }),
              IconButton(icon: const Icon(Icons.arrow_forward, size: 18), onPressed: () { setState(() { if (_cMonth == 12) { _cMonth = 1; _cYear++; } else { _cMonth++; } }); _refresh(); }),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Row(children: [
            _sBox('আয়', BHelper.taka(_mInc), Colors.green),
            const SizedBox(width: 4),
            _sBox('ব্যয়', BHelper.taka(_mExp), Colors.redAccent),
            const SizedBox(width: 4),
            _sBox('উদ্বৃত্ত', BHelper.taka(_mInc - _mExp), Colors.teal),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white, padding: EdgeInsets.zero), icon: const Icon(Icons.add, size: 14), label: const Text('আয়', style: TextStyle(fontSize: 11)), onPressed: () => _addCashbook(true))),
            const SizedBox(width: 4),
            Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800], foregroundColor: Colors.white, padding: EdgeInsets.zero), icon: const Icon(Icons.remove, size: 14), label: const Text('ব্যয়', style: TextStyle(fontSize: 11)), onPressed: () => _addCashbook(false))),
            const SizedBox(width: 4),
            IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.blueGrey[800]), icon: const Icon(Icons.swap_horiz, color: Colors.white, size: 16), onPressed: _addTransfer),
          ]),
        ),
        const Divider(height: 6),
        Expanded(
          child: filtered.isEmpty ? const Center(child: Text('কোন লেনদেন নেই')) : ListView.separated(
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, idx) {
              final e = filtered[idx], isInc = e['type'] == 'INCOME', isTrf = e['type'] == 'TRANSFER', meth = e['payment_method'];
              String ml = meth == 'BANK' ? 'ব্যাংক' : (meth == 'CASH_TO_BANK' ? 'ক্যাশ➔ব্যাংক' : (meth == 'BANK_TO_CASH' ? 'ব্যাংক➔ক্যাশ' : 'নগদ'));
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -2),
                onTap: () => _showCashbookDetails(e),
                title: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(e['category'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('${isInc ? "+ " : (isTrf ? "" : "- ")}${BHelper.taka(e['amount'] as int)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isInc ? Colors.green[800] : (isTrf ? Colors.blue[800] : Colors.red[800]))),
                ]),
                subtitle: Text('${e['date'].toString().substring(0, 10)} | $ml${e['voucher_no'] != null && e['voucher_no'].toString().isNotEmpty ? " | ভাউচার: ${e['voucher_no']}" : ""}${e['note'] != null && e['note'].toString().isNotEmpty ? " | ${e['note']}" : ""}', style: const TextStyle(fontSize: 10)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.teal),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 16),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (delCtx) => AlertDialog(
                            title: const Text('মুছে ফেলবেন?'),
                            content: Text('আপনি কি নিশ্চিত "${e['category']}" (${BHelper.taka(e['amount'] as int)}) এন্ট্রিটি মুছে ফেলতে চান?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(delCtx), child: const Text('না, রাখুন')),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800], foregroundColor: Colors.white),
                                onPressed: () async {
                                  await _db!.delete('cashbook', where: 'id=?', whereArgs: [e['id']]);
                                  await _db!.delete('cashbook_items', where: 'cashbook_id=?', whereArgs: [e['id']]);
                                  Navigator.pop(delCtx);
                                  _refresh();
                                },
                                child: const Text('হ্যাঁ, মুছুন'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sBox(String t, String v, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: c.withAlpha(20), borderRadius: BorderRadius.circular(4)),
      child: Column(children: [Text(t, style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.bold)), Text(v, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c))]),
    ),
  );

  void _showAuditPdfDialog(List<Map<String, Object?>> incs, List<Map<String, Object?>> exps) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.all(10),
        content: SingleChildScrollView(
          child: RepaintBoundary(
            key: _auditKey,
            child: Container(
              width: 340, padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.teal.shade800, width: 2)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Column(children: [
                      const Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.teal)),
                      Text('মাসিক অডিট স্টেটমেন্ট — ${BHelper.mNames[_cMonth]} $_cYear', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      Text('রিপোর্ট তৈরির তারিখ: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}', style: const TextStyle(fontSize: 9, color: Colors.grey)),
                    ]),
                  ),
                  const Divider(thickness: 1.5),
                  const Text('আয়ের বিবরণী:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green)),
                  ...incs.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('• ${r['category']}', style: const TextStyle(fontSize: 10)),
                      Text('৳ ${BHelper.toBn((r['s'] as int) ~/ 100)}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ]),
                  )),
                  Align(alignment: Alignment.centerRight, child: Text('মোট আয়: ৳ ${BHelper.toBn(_mInc ~/ 100)}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green))),
                  const Divider(),
                  const Text('ব্যয়ের বিবরণী:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.redAccent)),
                  ...exps.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('• ${r['category']}', style: const TextStyle(fontSize: 10)),
                      Text('৳ ${BHelper.toBn((r['s'] as int) ~/ 100)}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ]),
                  )),
                  Align(alignment: Alignment.centerRight, child: Text('মোট ব্যয়: ৳ ${BHelper.toBn(_mExp ~/ 100)}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.redAccent))),
                  const Divider(thickness: 1.5),
                  Container(
                    width: double.infinity, padding: const EdgeInsets.all(6),
                    color: Colors.teal.shade50,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('হাতে নগদ স্থিতি: ৳ ${BHelper.toBn(_cash ~/ 100)}', style: const TextStyle(fontSize: 10)),
                      Text('ব্যাংক স্থিতি: ৳ ${BHelper.toBn(_bank ~/ 100)}', style: const TextStyle(fontSize: 10)),
                      Text('সর্বমোট তহবিল: ৳ ${BHelper.toBn((_cash + _bank) ~/ 100)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal)),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('ক্যাশিয়ার স্বাক্ষর', style: TextStyle(fontSize: 8, color: Colors.grey)),
                      Text('সভাপতি / সম্পাদক স্বাক্ষর', style: TextStyle(fontSize: 8, color: Colors.grey)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বন্ধ')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white),
            icon: const Icon(Icons.picture_as_pdf, size: 14), label: const Text('PDF ডাউনলোড'),
            onPressed: () => _exportBoundaryToPdf(_auditKey, 'Miapara_Audit_${_cYear}_$_cMonth', context, 'অডিট স্টেটমেন্ট PDF Download ফোল্ডারে সেভ হয়েছে!'),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          color: Colors.teal.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('কমিটি মিটিং অডিট স্টেটমেন্ট', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const Text('মাসিক আয়-ব্যয়ের হিসাব PDF ডাউনলোড করুন অথবা হোয়াটসঅ্যাপে পাঠান', style: TextStyle(fontSize: 10, color: Colors.black54)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal[800], foregroundColor: Colors.white),
                        icon: const Icon(Icons.picture_as_pdf, size: 14),
                        label: const Text('PDF স্টেটমেন্ট', style: TextStyle(fontSize: 11)),
                        onPressed: () async {
                          final mp = '$_cYear-${_cMonth.toString().padLeft(2, '0')}';
                          final incs = await _db!.rawQuery("SELECT category, SUM(amount) as s FROM cashbook WHERE type='INCOME' AND substr(date,1,7)=? GROUP BY category", [mp]);
                          final exps = await _db!.rawQuery("SELECT category, SUM(amount) as s FROM cashbook WHERE type='EXPENSE' AND substr(date,1,7)=? GROUP BY category", [mp]);
                          _showAuditPdfDialog(incs, exps);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[800], foregroundColor: Colors.white),
                        icon: const Icon(Icons.copy, size: 14),
                        label: const Text('টেক্সট কপি', style: TextStyle(fontSize: 11)),
                        onPressed: () async {
                          final mp = '$_cYear-${_cMonth.toString().padLeft(2, '0')}';
                          final incs = await _db!.rawQuery("SELECT category, SUM(amount) as s FROM cashbook WHERE type='INCOME' AND substr(date,1,7)=? GROUP BY category", [mp]);
                          final exps = await _db!.rawQuery("SELECT category, SUM(amount) as s FROM cashbook WHERE type='EXPENSE' AND substr(date,1,7)=? GROUP BY category", [mp]);
                          StringBuffer sb = StringBuffer();
                          sb.writeln('🕌 মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ\nমাসিক অডিট স্টেটমেন্ট — ${BHelper.mNames[_cMonth]} $_cYear\n--------------------------\nআয়:');
                          for (var r in incs) { sb.writeln('• ${r['category']}: ৳${(r['s'] as int) ~/ 100}'); }
                          sb.writeln('মোট আয়: ৳${_mInc ~/ 100}\n\nব্যয়:');
                          for (var r in exps) { sb.writeln('• ${r['category']}: ৳${(r['s'] as int) ~/ 100}'); }
                          sb.writeln('মোট ব্যয়: ৳${_mExp ~/ 100}\n--------------------------\nতহবিল স্থিতি:\nহাতে নগদ: ৳${_cash ~/ 100}\nব্যাংক স্থিতি: ৳${_bank ~/ 100}\nসর্বমোট তহবিল: ৳${(_cash + _bank) ~/ 100}');
                          Clipboard.setData(ClipboardData(text: sb.toString()));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('অডিট স্টেটমেন্ট কপি হয়েছে! হোয়াটসঅ্যাপে পাঠান।')));
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // টেলিগ্রাম ক্লাউড ব্যাকআপ কার্ড
        Card(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.send, color: Colors.blue, size: 22),
                    SizedBox(width: 8),
                    Text('টেলিগ্রাম ক্লাউড ব্যাকআপ (অটো ও ম্যানুয়াল)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'অ্যাপে যেকোনো এন্ট্রি করার সাথে সাথে স্বয়ংক্রিয়ভাবে আপনার টেলিগ্রামে ব্যাকআপ ফাইল চলে যাবে। যেকোনো সময় নিচের বাটনে চাপ দিয়েও ব্যাকআপ পাঠাতে পারেন।',
                  style: TextStyle(fontSize: 10, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[700], foregroundColor: Colors.white),
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('টেলিগ্রামে ব্যাকআপ পাঠান'),
                    onPressed: () => _sendBackupToTelegram(showToast: true),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.settings, size: 16),
                    label: const Text('Telegram সেটআপ / Bot Token দিন'),
                    onPressed: _configureTelegram,
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 8),

        ListTile(
          tileColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          leading: const Icon(Icons.settings_backup_restore, color: Colors.green),
          title: const Text('কোড পেস্ট করে রিস্টোর করুন', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          subtitle: const Text('টেলিগ্রাম বা ব্যাকআপ ফাইলের কোড পেস্ট করে ডাটা ফিরিয়ে আনুন', style: TextStyle(fontSize: 9)),
          onTap: () async {
            final c = TextEditingController();
            // টেলিগ্রাম থেকে কোড কপি করে আনলে নিজে থেকেই পেস্ট হয়ে যাবে
            try {
              final clipData = await Clipboard.getData(Clipboard.kTextPlain);
              if (clipData != null && clipData.text != null && clipData.text!.contains('miapara_master_v8')) {
                c.text = clipData.text!;
              }
            } catch (_) {}

            if (!context.mounted) return;
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('রিস্টোর কোড পেস্ট করুন'),
                content: TextField(
                  controller: c,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'এখানে কপি করা কোড পেস্ট করুন...',
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
                  ElevatedButton(
                    onPressed: () async {
                      final text = c.text.trim();
                      if (text.isEmpty) return;
                      await _restoreFromJsonString(text);
                      Navigator.pop(ctx);
                    },
                    child: const Text('রিস্টোর'),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
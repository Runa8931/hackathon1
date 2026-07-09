// 親機Arduino（テンポ生成・全体のクロックマスター）
// ・可変抵抗器の値からBPM(20〜700)を算出する
// ・算出したBPMに従って一定間隔でSerial1（ハードUART）へ現在のBPM値（数値）を送信する
//   ※送っているのはBPMの数値だが、受信側（子機）は値の中身は使わず、
//     「1つ届いた」という事実だけを拍の合図として扱う。つまり値そのものより
//     「送信されたタイミング」が重要。
// ・拍を送るたびに基板上のLED(13番ピン)を短く光らせ、テンポを目視できるようにする
// ・停止時（つまみを最小付近まで下げたとき）は送信を止めて沈黙する（0などは送らない）
// ・子機Arduino（snow_density.ino）へは直結のSerial1で送る想定。PCへは直接送らない。

const int  LED_PIN      = 13;   // 拍を目視確認するためのLED（基板内蔵LED）
const int  POT_PIN      = A0;   // 可変抵抗器を接続するアナログ入力ピン
const int  LED_ON_MS    = 30;   // 1拍ごとにLEDを光らせる時間[ms]
const int  BPM_MIN      = 20;   // BPM下限
const int  BPM_MAX      =700;   // BPM上限
const int  HYSTERESIS   = 8;    // つまみのノイズ対策：この値未満の微小変化は無視する（BPMのばたつき防止）
const int  STOP_THRESHOLD = 20;  // この値以下で停止

int  currentBpm      = 60;    // 現在のBPM
long beatIntervalMs  = 1000;  // 1拍あたりの周期[ms]（60000 / BPM で算出される）
long lastBeatTime    = 0;     // 直近の拍を送信した時刻[ms]
long ledOffTime      = 0;     // LEDを消灯すべき時刻[ms]
bool ledOn           = false; // 現在LEDが点灯中かどうか
int  prevPotRaw      = -1;    // 前回読み取った可変抵抗器の生値（ヒステリシス判定用）
bool isStopped       = false;  // 停止状態フラグ

void setup() {
  pinMode(LED_PIN, OUTPUT);  // LEDピンを出力に設定
  Serial1.begin(9600);       // 子機との通信用UARTを開始
  lastBeatTime = millis();   // 起動時刻を基準にする
  updateBpm();               // 起動直後に一度BPMを読み取っておく
}

void loop() {
  long now = millis();

  updateBpm();  // 毎回つまみを確認し、BPM（または停止状態）を更新する

  // 停止中は何もしない
  if (isStopped) {
    digitalWrite(LED_PIN, LOW);  // LEDを消しておく
    return;                      // 拍を送信せずにloopを抜ける（つまみを上げるまで沈黙）
  }

  // 目標時刻に到達したら拍を1つ送信する
  if (now - lastBeatTime >= beatIntervalMs) {
    // 次の目標時刻は「今の時刻」ではなく「前回の目標時刻 + 周期」で決める。
    // = now にすると loop() の実行遅延が毎回積み重なり、拍が徐々に遅れていく（クロックドリフト）。
    // += beatIntervalMs にすることで、ズレを蓄積させずに一定間隔を保つ。
    lastBeatTime += beatIntervalMs;

    Serial1.println(currentBpm);  // 現在のBPM値（数値）を送信する。この値の到着そのものが拍の合図になる

    digitalWrite(LED_PIN, HIGH);        // 拍に合わせてLEDを点灯
    ledOn      = true;
    ledOffTime = lastBeatTime + LED_ON_MS;  // LED_ON_MS後に消灯する予定時刻を記録
  }

  // 点灯中のLEDが消灯予定時刻を過ぎたら消す
  if (ledOn && now >= ledOffTime) {
    digitalWrite(LED_PIN, LOW);
    ledOn = false;
  }
}

// 可変抵抗器を読み取り、BPM（または停止状態）を更新する
void updateBpm() {
  int raw = analogRead(POT_PIN);  // 可変抵抗器の値(0..1023)を読む

  // ヒステリシス：前回値からの変化が小さいときは何もしない（ノイズによる細かなBPM変動を防ぐ）
  if (prevPotRaw >= 0 && abs(raw - prevPotRaw) < HYSTERESIS) return;
  prevPotRaw = raw;

  // 可変抵抗が最小付近なら停止
  if (raw <= STOP_THRESHOLD) {
    isStopped = true;
    return;
  }

  isStopped  = false;
  // つまみの値(STOP_THRESHOLD+1..1023)をBPM(BPM_MIN..BPM_MAX)へ変換する
  int newBpm = map(raw, STOP_THRESHOLD + 1, 1023, BPM_MIN, BPM_MAX);
  if (newBpm != currentBpm) {
    currentBpm     = newBpm;             // BPMを更新
    beatIntervalMs = 60000L / currentBpm; // BPMから1拍あたりの周期[ms]を算出
  }
}

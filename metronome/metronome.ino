// 親機Arduino（テンポ生成・全体のクロックマスター）
// ・可変抵抗器の値からBPM(20〜80)を算出する
// ・算出したBPMに従って一定間隔でSerial1（ハードUART）へ拍イベントを送信する
//   停止時: 0 を1回だけ送信
//   演奏中: 拍が来るたびに現在のBPM値をそのまま送信（受信側は「0か非0か」だけを見て拍の合図として扱う）
// ・子機Arduino（snow_density.ino）へは直結のSerial1で送る想定。PCへは直接送らない。

const int POT_PIN   = A0;   // 可変抵抗器を接続するアナログ入力ピン
const int BPM_MIN   = 20;   // BPM下限（ゼロ除算回避のため0にしない）
const int BPM_MAX   = 80;   // BPM上限
const int STOP_LEVEL = 10;  // つまみがこの値以下なら停止とみなす

int  bpm          = BPM_MIN;          // 現在のBPM
long beatInterval = 60000L / BPM_MIN; // 1拍あたりの周期[ms]
long lastBeatTime = 0;                // 直近のbeat送信時刻[ms]
bool playing      = false;            // 演奏中かどうか

void setup() {
  Serial1.begin(9600);       // UARTシリアル通信の開始
  lastBeatTime = millis();   // 起動時刻を基準にする
}

void loop() {
  long now = millis();
  int potValue = analogRead(POT_PIN);   // 可変抵抗器の値(0..1023)

  // つまみを一番低くしたら音楽を止める
  if (potValue <= STOP_LEVEL) {
    if (playing) {
      Serial1.println(0);   // 停止を表す0を1回だけ送信する
      playing = false;
    }
    return;                 // 停止中はbeatを送らない（つまみを上げるまで何も送らない）
  }

  // 停止から復帰した直後はタイミングを今に合わせる（連続送信の防止）
  // これをしないと、停止していた間の経過時間ぶん beatInterval を超えてしまい、
  // 復帰直後に拍が連続で送信されてしまう。
  if (!playing) {
    lastBeatTime = now;
    playing = true;
  }

  // 可変抵抗器の値をBPM(20..80)へ変換する
  bpm = map(potValue, STOP_LEVEL + 1, 1023, BPM_MIN, BPM_MAX);
  bpm = constrain(bpm, BPM_MIN, BPM_MAX);

  // BPMから1拍あたりの周期[ms]を算出する（60000ms / BPM）
  beatInterval = 60000L / bpm;

  // 目標時刻に到達したらBPMの数値だけを送信する
  if (now - lastBeatTime >= beatInterval) {
    // 次の目標時刻は「今の時刻」ではなく「前回の目標時刻 + 周期」で決める。
    // = now にしてしまうと loop() の実行遅延が毎回積み重なり、拍の間隔が徐々に遅れていく（クロックドリフト）。
    // += beatInterval にすることで、ズレを蓄積させずに一定間隔を保つ。
    lastBeatTime += beatInterval;
    Serial1.println(bpm);          // 現在のBPM値（数値のみ）を送信する。値そのものより「送信された」ことが拍の合図として使われる
  }
}
// 楽器側Arduino（輪唱対応 ＋ 雪の演出）── 4つ目（8拍遅れ）
// ・自分が歌い出してから楽譜を最後まで演奏する間だけ雪を降らせる
// ・楽譜を最後まで演奏したら発音も雪も止める（ループしない）
// ・雪は横にゆらゆら揺れながら降る（湧く間隔・落下速度は固定値。BPMには連動しない）
//
// このArduinoは親機（metronome.ino）からSerial1で拍イベントを受け取り、
// 1) 輪唱の歌い出しタイミングをずらす（MY_OFFSET拍待ってから発音を開始する）
// 2) 発音の合図（0/1）をSerial（USB）経由でPC側のProcessingへ中継する
// 3) 自分が歌っている間だけ、LEDマトリクスに雪を降らせる演出を行う
// という3つの役割を持つ。

#include "Arduino_LED_Matrix.h"

ArduinoLEDMatrix matrix;

// ---------- 輪唱・演奏パラメータ ----------
const int MY_OFFSET   = 32;   // 8拍遅れ（歌い出しまでの拍数）

// この楽器の楽譜を1周するのに必要な「1」の受信回数。
// Processing側は 1 を受けるたびに0.25拍進むので、
//   必要回数 = 楽譜の合計拍数 / 0.25
// リコーダー(ゆきやこんこ)は合計約34拍 → 34 / 0.25 = 136
const long SONG_TICKS = 128;

int  globalTick = 0;    // 歌い出しまでのカウント（MY_OFFSETに達するまで数える）
long playTicks  = 0;    // 歌い出してから送った「1」の数（SONG_TICKSと比較して終了判定に使う）
bool singing    = false; // 歌い出したか（雪を降らせてよい状態か）
bool finished   = false; // 楽譜を最後まで演奏し終えたか（終わったら雪だけ止める。音は止めない）

char buf[16];  // Serial1から受信した1行分の文字列を組み立てるバッファ
int idx = 0;   // buf内の書き込み位置

// ---------- 雪パラメータ ----------
// 雪の湧く間隔・落下速度はすべて固定値。BPM（テンポ）には連動させない仕様とした。
const int MATRIX_ROWS = 8;
const int MATRIX_COLS = 12;

const int SPAWN_INTERVAL_MS = 300;    // 雪が1粒湧いてから次が湧くまでの間隔[ms]

const int FALL_MS_FAST = 120;         // 落下が速い粒の所要時間[ms]（下限）
const int FALL_MS_SLOW = 320;         // 落下が遅い粒の所要時間[ms]（上限）
const int MAX_FLAKES = 60;            // 同時に降らせる雪粒の最大数

const int SWAY_MS_MIN = 200;          // 横揺れの間隔[ms]（下限）
const int SWAY_MS_MAX = 500;          // 横揺れの間隔[ms]（上限）

unsigned long lastSpawn = 0;   // 最後に雪を1粒湧かせた時刻[ms]

struct Flake {
  int  col;
  int  row;
  long fallMs;
  unsigned long lastFall;
  long swayMs;
  unsigned long lastSway;
  int  swayDir;
  bool active;
};

Flake flakes[MAX_FLAKES];
byte snowFrame[MATRIX_ROWS][MATRIX_COLS];

void setup() {
  Serial.begin(9600);   // PC(Processing)との通信用（USB）
  Serial1.begin(9600);  // 親機(metronome.ino)との通信用（ハードUART）

  matrix.begin();
  for (int i = 0; i < MAX_FLAKES; i++) flakes[i].active = false;  // 全ての雪粒を非表示状態にしておく
  clearFrame();
  renderSnow();
  randomSeed(analogRead(A0));  // 未接続ピンのノイズを乱数の種にする（雪の落ち方をランダムにするため）

  lastSpawn = millis();
}

void loop() {
  unsigned long now = millis();

  // --- 受信処理：Serial1（親機からの拍イベント）を1文字ずつ読み、改行が来たら1つの数値として処理する ---
  while (Serial1.available() > 0) {
    char c = Serial1.read();
    if (c == '\n' || c == '\r') {
      if (idx > 0) {
        buf[idx] = '\0';
        int value = atoi(buf);   // 受信した文字列を整数に変換
        handleValue(value);
        idx = 0;
      }
    } else if (idx < (int)sizeof(buf) - 1) {
      buf[idx++] = c;
    }
  }

  // --- 雪の湧き：歌っている間（singing かつ 未終了）だけ、一定間隔で新しい雪粒を1つ生成する ---
  if (singing && !finished &&
      (now - lastSpawn) >= (unsigned long)SPAWN_INTERVAL_MS) {
    lastSpawn = now;
    spawnFlake(now);
  }

  // --- 落下＋横揺れ（すでに降っている粒は、歌が終わっていても下まで落としきる） ---
  updateFlakes(now);
}

// 親機から受信した値を処理する。
// value == 0        : 停止の合図。輪唱の状態をリセットし、PCへも0を中継する。
// value != 0（0以外）: 拍が1つ来たという合図。値そのもの（BPM値）は使わず、
//                      「拍が来た」という事実だけをカウントに使う。
void handleValue(int value) {
  if (value == 0) {
    Serial.println(0);
    globalTick = 0;
    playTicks  = 0;
    singing    = false;
    finished   = false;
    return;
  }

  // ---- 輪唱の発音判定：MY_OFFSET拍待ってから歌い出す。一度歌い出したら音は絶対に止めない ----
  if (globalTick >= MY_OFFSET) {
    Serial.println(1);       // finishedでも必ず送る＝音は止まらない
    playTicks++;

    // 雪の制御だけ：一定数降らせたら雪を止める（音には一切触れない）
    if (!finished && playTicks >= SONG_TICKS) {
      finished = true;
      singing  = false;
    }
    if (!finished) {
      singing = true;
    }
  } else {
    globalTick++;  // 歌い出しまではカウントを進めるだけで、発音も雪もまだ発生させない
  }
}

// 空いている枠(flakes配列)を1つ探し、雪粒を1つ新規生成する。
// 落下速度・横揺れ間隔・揺れる向きはFALL_MS_FAST〜SLOW等の範囲でランダムに決め、
// 粒ごとに見た目がバラけるようにしている（この乱数はBPMとは無関係）。
void spawnFlake(unsigned long now) {
  int slot = -1;
  for (int i = 0; i < MAX_FLAKES; i++) {
    if (!flakes[i].active) { slot = i; break; }
  }
  if (slot < 0) return;  // 空き枠がなければ何もしない（MAX_FLAKES上限）

  flakes[slot].active   = true;
  flakes[slot].col      = random(0, MATRIX_COLS);  // 湧く列をランダムに決める
  flakes[slot].row      = 0;                       // 一番上の行から降り始める
  flakes[slot].fallMs   = random(FALL_MS_FAST, FALL_MS_SLOW + 1);
  flakes[slot].lastFall = now;
  flakes[slot].swayMs   = random(SWAY_MS_MIN, SWAY_MS_MAX + 1);
  flakes[slot].lastSway = now;
  flakes[slot].swayDir  = (random(0, 2) == 0) ? -1 : 1;  // 左右どちらに揺れ始めるかをランダムに決める
}

// 全ての雪粒について、横揺れと落下を時間経過に応じて進める。
// 見た目に変化があった（changed）ときだけLEDマトリクスを再描画し、無駄な描画更新を避けている。
void updateFlakes(unsigned long now) {
  bool changed = false;

  for (int i = 0; i < MAX_FLAKES; i++) {
    if (!flakes[i].active) continue;

    // 横揺れ：swayMs間隔ごとに1列分、左右どちらかへ動かす
    if ((now - flakes[i].lastSway) >= (unsigned long)flakes[i].swayMs) {
      flakes[i].lastSway = now;
      int newCol = flakes[i].col + flakes[i].swayDir;
      if (newCol < 0) {
        newCol = 1;
        flakes[i].swayDir = 1;   // 左端に達したら右向きに反転
      } else if (newCol >= MATRIX_COLS) {
        newCol = MATRIX_COLS - 2;
        flakes[i].swayDir = -1;  // 右端に達したら左向きに反転
      } else if (random(0, 100) < 30) {
        flakes[i].swayDir = -flakes[i].swayDir;  // 30%の確率で気まぐれに向きを変える
      }
      flakes[i].col = newCol;
      changed = true;
    }

    // 落下：fallMs間隔ごとに1行分下へ進める。最下段を超えたら非表示にして枠を空ける
    if ((now - flakes[i].lastFall) >= (unsigned long)flakes[i].fallMs) {
      flakes[i].lastFall = now;
      flakes[i].row++;
      changed = true;
      if (flakes[i].row >= MATRIX_ROWS) {
        flakes[i].active = false;
      }
    }
  }

  if (changed) {
    rebuildFrame();
    renderSnow();
  }
}

// 現在アクティブな雪粒の位置から、LEDマトリクス表示用の1フレーム分(snowFrame)を作り直す
void rebuildFrame() {
  clearFrame();
  for (int i = 0; i < MAX_FLAKES; i++) {
    if (!flakes[i].active) continue;
    int r = flakes[i].row;
    int c = flakes[i].col;
    if (r >= 0 && r < MATRIX_ROWS && c >= 0 && c < MATRIX_COLS) {
      snowFrame[r][c] = 1;
    }
  }
}

// フレームバッファ(snowFrame)を全消灯状態にする
void clearFrame() {
  for (int r = 0; r < MATRIX_ROWS; r++) {
    for (int c = 0; c < MATRIX_COLS; c++) {
      snowFrame[r][c] = 0;
    }
  }
}

// フレームバッファの内容をLEDマトリクスへ実際に表示する
void renderSnow() {
  matrix.renderBitmap(snowFrame, MATRIX_ROWS, MATRIX_COLS);
}


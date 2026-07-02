// 楽器側Arduino（輪唱対応 ＋ 雪の演出）── 4つ目（3拍遅れ）aa
// ・自分が歌い出してから楽譜を最後まで演奏する間だけ雪を降らせる
// ・楽譜を最後まで演奏したら発音も雪も止める（ループしない）
// ・雪は横にゆらゆら揺れ、受信BPMが速いほど密になる

#include "Arduino_LED_Matrix.h"

ArduinoLEDMatrix matrix;

// ---------- 輪唱・演奏パラメータ ----------
const int MY_OFFSET   = 32;   // 3拍遅れ（歌い出しまでの拍数）

// この楽器の楽譜を1周するのに必要な「1」の受信回数。
// Processing側は 1 を受けるたびに0.25拍進むので、
//   必要回数 = 楽譜の合計拍数 ÷ 0.25
// リコーダー(ゆきやこんこ)は合計約34拍 → 34 / 0.25 = 136
const long SONG_TICKS = 128;

int  globalTick = 0;    // 歌い出しまでのカウント
long playTicks  = 0;    // 歌い出してから送った「1」の数
bool singing    = false; // 歌い出したか
bool finished   = false; // 演奏を終えたか（終わったら雪も止める）

char buf[16];
int idx = 0;

// ---------- 雪パラメータ ----------
const int MATRIX_ROWS = 8;
const int MATRIX_COLS = 12;

const int BPM_MIN = 20;
const int BPM_MAX = 80;
const int SPAWN_INTERVAL_FAST = 90;   // 速い(密)ときの湧く間隔[ms]
const int SPAWN_INTERVAL_SLOW = 300;  // 遅い(まばら)ときの湧く間隔[ms]

const int FALL_MS_FAST = 120;         // 速い粒
const int FALL_MS_SLOW = 320;         // 遅い粒
const int MAX_FLAKES = 60;

const int SWAY_MS_MIN = 200;          // 横揺れの間隔[ms]
const int SWAY_MS_MAX = 500;

int spawnIntervalMs = SPAWN_INTERVAL_SLOW;
unsigned long lastSpawn = 0;

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
  Serial.begin(9600);
  Serial1.begin(9600);

  matrix.begin();
  for (int i = 0; i < MAX_FLAKES; i++) flakes[i].active = false;
  clearFrame();
  renderSnow();
  randomSeed(analogRead(A0));

  lastSpawn = millis();
}

void loop() {
  unsigned long now = millis();

  // --- 受信処理 ---
  while (Serial1.available() > 0) {
    char c = Serial1.read();
    if (c == '\n' || c == '\r') {
      if (idx > 0) {
        buf[idx] = '\0';
        int value = atoi(buf);
        handleValue(value);
        idx = 0;
      }
    } else if (idx < (int)sizeof(buf) - 1) {
      buf[idx++] = c;
    }
  }

  // --- 雪の湧き：歌っている間（singing かつ 未終了）だけ ---
  if (singing && !finished &&
      (now - lastSpawn) >= (unsigned long)spawnIntervalMs) {
    lastSpawn = now;
    spawnFlake(now);
  }

  // --- 落下＋横揺れ（すでに降っている粒は下まで落としきる） ---
  updateFlakes(now);
}

void handleValue(int value) {
  if (value == 0) {
    Serial.println(0);
    globalTick = 0;
    playTicks  = 0;
    singing    = false;
    finished   = false;
    return;
  }

  // ---- 輪唱の発音判定：音は絶対に止めない ----
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
    globalTick++;
  }
}

void spawnFlake(unsigned long now) {
  int slot = -1;
  for (int i = 0; i < MAX_FLAKES; i++) {
    if (!flakes[i].active) { slot = i; break; }
  }
  if (slot < 0) return;

  flakes[slot].active   = true;
  flakes[slot].col      = random(0, MATRIX_COLS);
  flakes[slot].row      = 0;
  flakes[slot].fallMs   = random(FALL_MS_FAST, FALL_MS_SLOW + 1);
  flakes[slot].lastFall = now;
  flakes[slot].swayMs   = random(SWAY_MS_MIN, SWAY_MS_MAX + 1);
  flakes[slot].lastSway = now;
  flakes[slot].swayDir  = (random(0, 2) == 0) ? -1 : 1;
}

void updateFlakes(unsigned long now) {
  bool changed = false;

  for (int i = 0; i < MAX_FLAKES; i++) {
    if (!flakes[i].active) continue;

    // 横揺れ
    if ((now - flakes[i].lastSway) >= (unsigned long)flakes[i].swayMs) {
      flakes[i].lastSway = now;
      int newCol = flakes[i].col + flakes[i].swayDir;
      if (newCol < 0) {
        newCol = 1;
        flakes[i].swayDir = 1;
      } else if (newCol >= MATRIX_COLS) {
        newCol = MATRIX_COLS - 2;
        flakes[i].swayDir = -1;
      } else if (random(0, 100) < 30) {
        flakes[i].swayDir = -flakes[i].swayDir;
      }
      flakes[i].col = newCol;
      changed = true;
    }

    // 落下
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

void clearFrame() {
  for (int r = 0; r < MATRIX_ROWS; r++) {
    for (int c = 0; c < MATRIX_COLS; c++) {
      snowFrame[r][c] = 0;
    }
  }
}

void renderSnow() {
  matrix.renderBitmap(snowFrame, MATRIX_ROWS, MATRIX_COLS);
}